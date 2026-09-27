/* Canonical Contractor link. Drafts and immutable retry requests live in memory and,
   where the browser allows it, in IndexedDB on this device, so an unsent fix survives
   a reload, a discarded tab or lost signal (F10). The stored record is keyed by a
   SHA-256 of this link, never the link itself; it holds only this link's notes, photos
   and idempotent retry commands, and is deleted when the server confirms the
   submission, after 7 days, or once the link has expired. Nothing goes into cookies,
   localStorage or sessionStorage. */
(() => {
  'use strict';
  const token = location.pathname.split('/')[2];
  const root = `/api/v2/contractor/${encodeURIComponent(token)}`;
  const content = document.querySelector('#content');
  const drafts = new Map();
  const histories = new Map();
  const labels = {open:'Open',in_progress:'In progress',awaiting_review:'Awaiting review',changes_requested:'Changes requested',closed:'Closed · accepted'};
  const LIMIT = 10485760, MAX_EDGE = 4096, DRAFT_DAYS = 7;
  const uuid = () => crypto.randomUUID();
  let current, page = 1, busy = false, pageError = '', notice = '', offline = navigator.onLine === false, storageReady = false;
  let deviceId = uuid();
  let stored = null;
  const meta = () => ({operationId:uuid(),deviceId:deviceId});
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const actionable = item => current?.mode === 'completion' && ['open','in_progress','changes_requested'].includes(item.status);
  const date = value => value ? new Intl.DateTimeFormat('en-GB',{day:'numeric',month:'short',year:'numeric'}).format(new Date(value.length === 10 ? value+'T12:00:00Z' : value)) : '';
  const hex = buffer => Array.from(new Uint8Array(buffer)).map(b=>b.toString(16).padStart(2,'0')).join('');
  const interrupted = () => Object.assign(new Error(navigator.onLine === false
    ? 'No signal. Your notes and photos are kept. Try again when you are back online.'
    : 'The connection was interrupted. Your notes and photos are kept. Try again.'),{network:true});

  /* This device's copy of unsent drafts for this link only. Every call degrades to
     "not saved" rather than failing the page when storage is blocked or full. */
  const device = (() => {
    let opened, scoped;
    const scope = () => scoped ||= crypto.subtle.digest('SHA-256',new TextEncoder().encode('snaglist-contractor-draft-v1\n'+token)).then(hex).catch(()=>null);
    const db = () => opened ||= new Promise(resolve => {
      try {
        const req = indexedDB.open('snaglist-contractor-drafts',1);
        req.onupgradeneeded = () => { const d = req.result; d.createObjectStore('drafts',{keyPath:'key'}).createIndex('scope','scope'); d.createObjectStore('devices',{keyPath:'scope'}); };
        req.onsuccess = () => resolve(req.result); req.onerror = () => resolve(null); req.onblocked = () => resolve(null);
      } catch { resolve(null); }
    });
    const run = async (name, mode, work) => {
      const d = await db(); if (!d) return undefined;
      return new Promise(resolve => {
        try { const t = d.transaction(name,mode), req = work(t.objectStore(name)); t.oncomplete = () => resolve(req && 'result' in req ? req.result : true); t.onerror = t.onabort = () => resolve(undefined); }
        catch { resolve(undefined); }
      });
    };
    return {
      async ready() { return Boolean(await db()) && Boolean(await scope()); },
      async deviceId() { const s = await scope(); if (!s) return null; const found = await run('devices','readonly',st=>st.get(s)); if (found?.deviceId) return found.deviceId; const id = uuid(); return await run('devices','readwrite',st=>st.put({scope:s,deviceId:id,createdAt:Date.now()})) ? id : null; },
      async all() { const s = await scope(); if (!s) return []; return (await run('drafts','readonly',st=>st.index('scope').getAll(s))) || []; },
      async put(snagId, value) { const s = await scope(); if (!s) return false; return Boolean(await run('drafts','readwrite',st=>st.put({...value,key:s+':'+snagId,scope:s,snagId,savedAt:Date.now()}))); },
      async remove(snagId) { const s = await scope(); if (s) await run('drafts','readwrite',st=>st.delete(s+':'+snagId)); },
      async purge() {
        const now = Date.now();
        await run('drafts','readwrite',st=>{ const req = st.openCursor(); req.onsuccess = () => { const c = req.result; if (!c) return; const v = c.value; if (!(v.savedAt > now - DRAFT_DAYS*86400000) || (v.linkExpiresAt && Date.parse(v.linkExpiresAt) < now)) c.delete(); c.continue(); }; return null; });
      }
    };
  })();
  function persist(id) {
    const draft = drafts.get(id); if (!draft || !storageReady) return;
    if (!(draft.note || draft.files.length || draft.request)) { device.remove(id); return; }
    device.put(id,{note:draft.note,intent:draft.intent,revision:draft.revision,workflowRevision:draft.workflowRevision,request:draft.request||null,
      linkExpiresAt:current?.expiresAt||null,files:draft.files.map(f=>({file:f.file,command:f.command||null,ready:Boolean(f.ready)}))});
  }
  const persistSoon = (() => { const timers = new Map(); return id => { clearTimeout(timers.get(id)); timers.set(id,setTimeout(()=>persist(id),400)); }; })();
  const preview = file => { try { return URL.createObjectURL(file); } catch { return ''; } };
  const release = files => files.forEach(f => { if (f.preview) URL.revokeObjectURL(f.preview); });
  function forget(id) { const draft = drafts.get(id); if (draft) release(draft.files); drafts.delete(id); device.remove(id); }

  async function request(path, body, method = 'POST', mime = 'application/json') {
    let response;
    try { response = await fetch(path, {method,credentials:'same-origin',cache:'no-store',headers:method === 'GET' ? {} : {'Content-Type':mime,'X-Snaglist-Contractor':'1'},body:body === undefined ? undefined : mime === 'application/json' ? JSON.stringify(body) : body}); }
    catch { throw interrupted(); }
    let result; try { result = await response.json(); } catch { throw interrupted(); }
    if (!response.ok) throw Object.assign(new Error(result.reason || 'This action could not be completed.'),{status:response.status,identifier:result.identifier});
    return result;
  }
  /* The photo PUT reports real upload progress; the same idempotent command is reused
     on every retry, so a lost acknowledgement never creates a second photo. */
  function upload(path, bytes, mime, progress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('PUT',path); xhr.setRequestHeader('Content-Type',mime); xhr.setRequestHeader('X-Snaglist-Contractor','1'); xhr.timeout = 180000;
      xhr.upload.onprogress = event => { if (event.lengthComputable) progress(event.loaded / event.total); };
      xhr.upload.onload = () => progress(1);
      xhr.onload = () => {
        let result; try { result = JSON.parse(xhr.responseText); } catch { reject(interrupted()); return; }
        if (xhr.status < 200 || xhr.status > 299) reject(Object.assign(new Error(result.reason || 'This photo could not be uploaded.'),{status:xhr.status,identifier:result.identifier}));
        else resolve(result);
      };
      xhr.onerror = xhr.ontimeout = xhr.onabort = () => reject(interrupted());
      xhr.send(bytes);
    });
  }
  /* Camera output larger than the server accepts (over 10 MB, 40 megapixels or 12,000
     pixels a side), or in a format it does not take, is redrawn upright as a JPEG no
     more than 4,096 pixels on its long edge. Anything else is sent exactly as chosen. */
  async function prepare(file) {
    const heic = /^image\/hei[cf]/i.test(file.type) || (!file.type && /\.(heic|heif)$/i.test(file.name));
    const supported = ['image/jpeg','image/png'].includes(file.type);
    if (!supported && !heic) throw new Error('Choose JPEG or PNG photos up to 10 MB each.');
    if (file.size <= 0) throw new Error('That photo is empty. Choose it again.');
    let redraw = !supported || file.size > LIMIT, bitmap;
    if (!redraw && file.size > 6291456) {
      try { bitmap = await createImageBitmap(file,{imageOrientation:'from-image'}); redraw = bitmap.width * bitmap.height > 40000000 || Math.max(bitmap.width,bitmap.height) > 12000; } catch { bitmap = undefined; }
    }
    if (!redraw) { bitmap?.close?.(); return file; }
    try {
      bitmap ||= await createImageBitmap(file,{imageOrientation:'from-image'});
      const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width,bitmap.height));
      const canvas = document.createElement('canvas'); canvas.width = Math.max(1,Math.round(bitmap.width*scale)); canvas.height = Math.max(1,Math.round(bitmap.height*scale));
      const context = canvas.getContext('2d'); context.fillStyle = '#fff'; context.fillRect(0,0,canvas.width,canvas.height); context.drawImage(bitmap,0,0,canvas.width,canvas.height); bitmap.close?.();
      for (const quality of [0.9,0.8,0.7]) {
        const blob = await new Promise(resolve => canvas.toBlob(resolve,'image/jpeg',quality));
        if (blob && blob.size > 0 && blob.size <= LIMIT) return new File([blob],(file.name || 'photo').replace(/\.[^.]*$/,'')+'.jpg',{type:'image/jpeg',lastModified:file.lastModified});
      }
    } catch { /* fall through to the explanation below */ }
    throw new Error(heic ? 'This photo format could not be converted on this device. Choose a JPEG or PNG photo.' : 'This photo is too large to send. Choose a photo up to 10 MB.');
  }
  const photoURL = (item,photo) => `${root}/snags/${item.id}/media/${photo.id}/content`;
  function renderPhotos(item) {
    if (!item.photos.length) return '<p class="empty-photo">No shared photos for this snag.</p>';
    return `<div class="photo-grid">${item.photos.map(p => `<button class="photo-button" data-photo="${p.id}" data-snag="${item.id}" aria-label="Enlarge ${escape(p.label.toLowerCase())} photo for ${escape(item.reference)}"><img src="${photoURL(item,p)}" alt="${escape(p.label)} evidence for ${escape(item.title)}" loading="lazy"><span>${escape(p.label)} photo · Enlarge</span></button>`).join('')}</div>`;
  }
  function fileState(file) {
    if (file.ready) return 'Uploaded and checked';
    return file.progress || (file.command ? 'Not sent yet · will retry' : 'Ready to upload');
  }
  function submission(item,draft) {
    const stale = draft.revision !== item.revision || draft.workflowRevision !== item.workflowRevision;
    const locked = busy || Boolean(draft.request) || stale;
    const ready = draft.files.filter(f=>f.ready).length;
    return `<form class="submission" data-submit="${item.id}">
      <h3>Submit your fix for review</h3><p class="help">Add after photos showing the completed work. The manager will review your evidence before this snag is closed.</p>
      ${draft.restored?`<p class="notice restored">Restored from this device: the notes and photos you had not sent yet. <button type="button" class="link-button" data-discard="${item.id}" ${busy?'disabled':''}>Discard them</button></p>`:''}
      ${stale ? `<div class="notice">The snag has changed since you started. Check the current details and feedback above. Your notes and photos are retained.<div class="actions"><button type="button" class="secondary" data-rebase="${item.id}" ${busy?'disabled':''}>I have reviewed the latest details</button></div></div>`:''}
      <label for="note-${item.id}">What did you fix?</label><textarea id="note-${item.id}" data-note="${item.id}" maxlength="10000" ${locked?'readonly':''} placeholder="Describe the repair and any checks you carried out">${escape(draft.note)}</textarea>
      <p class="field-label">After photos <span class="help">(required)</span></p><p class="help">JPEG or PNG. Larger camera photos are resized to fit 10 MB. Up to 20 photos.</p>
      <button type="button" class="secondary" data-choose="${item.id}" aria-describedby="terms-${item.id}" ${locked||draft.preparing?'disabled':''}>Add after photos</button>
      <input id="files-${item.id}" data-files="${item.id}" type="file" accept="image/jpeg,image/png" multiple hidden tabindex="-1" aria-hidden="true" ${locked?'disabled':''}>
      ${draft.preparing?`<p class="help" role="status">Preparing ${draft.preparing} photo${draft.preparing===1?'':'s'}…</p>`:''}
      <div class="upload-list">${draft.files.map((file,i) => `<div class="upload-file">${file.preview?`<img class="upload-thumb" src="${file.preview}" alt="">`:''}<span class="upload-name">${escape(file.file.name)}<br><span class="help${file.ready?' done':''}" id="upload-${item.id}-${i}">${escape(fileState(file))}</span></span><button class="secondary" type="button" data-remove="${i}" data-snag="${item.id}" ${locked?'disabled':''}>Remove</button></div>`).join('')}</div>
      ${draft.files.length?`<p class="help" aria-live="polite">${ready} of ${draft.files.length} photo${draft.files.length===1?'':'s'} uploaded${storageReady?' · Unsent work is kept on this device':''}</p>`:''}
      <p class="help terms-notice" id="terms-${item.id}">Your photos and notes will be shared with the project team and may appear in project reports. Upload only information you have permission to share. By submitting, you agree to the <a href="https://usesnaglist.com/terms#contractor-links" target="_blank" rel="noopener noreferrer" aria-label="Contractor link terms (opens in a new tab)">Contractor link terms</a>. Read our <a href="https://usesnaglist.com/privacy" target="_blank" rel="noopener noreferrer" aria-label="privacy notice (opens in a new tab)">privacy notice</a> to understand how your information is used.</p>
      ${draft.error?`<p class="error" role="alert">${escape(draft.error)}</p>`:''}
      <div class="actions"><button type="submit" class="primary" aria-describedby="terms-${item.id}" ${busy||stale||draft.preparing?'disabled':''}>${busy?(draft.stage||'Sending your fix…'):draft.request?'Retry submission':'Submit for review'}</button><button type="button" class="secondary" data-cancel="${item.id}" ${busy?'disabled':''}>Back to snag</button></div>
      <p class="help">${storageReady?'You can leave this page: unsent notes and photos stay on this device for 7 days.':'Keep this page open while your photos upload.'} We’ll confirm when your fix has been sent for review.</p></form>`;
  }
  function card(item) {
    const draft = drafts.get(item.id), latest = item.submissions[0];
    const openForm = draft?.open && actionable(item);
    return `<article class="snag-card" id="snag-${item.id}" tabindex="-1"><div class="card-top"><span class="reference">${escape(item.reference)}</span><span class="status status-${escape(item.status)}">${escape(labels[item.status] || 'Status needs checking')}</span></div>
      <h2>${escape(item.title)}</h2><p class="location">${escape(item.location || 'Location not recorded')}${item.dueDate?` · Due ${escape(date(item.dueDate))}`:''}</p>
      ${item.description?`<p class="description">${escape(item.description)}</p>`:''}${renderPhotos(item)}
      ${item.status==='changes_requested'&&latest?.feedback?`<div class="feedback"><strong>The manager has requested changes</strong><p>${escape(latest.feedback)}</p></div>`:''}
      ${item.status==='awaiting_review'?'<div class="review-status"><strong>Submitted · awaiting manager review</strong><p>Completion evidence is awaiting review. The snag will close only when the manager accepts the fix.</p></div>':''}
      ${item.status==='closed'?'<div class="review-status accepted"><strong>Fix accepted · snag closed</strong><p>The manager has accepted the completed work. No further action is needed.</p></div>':''}
      ${actionable(item)&&!openForm?`<div class="actions">${item.status!=='in_progress'?`<button class="secondary" data-start="${item.id}" ${busy?'disabled':''}>Start work</button>`:''}<button class="primary" id="open-${item.id}" data-open="${item.id}" ${busy?'disabled':''}>${draft&&(draft.note||draft.files.length||draft.request)?'Continue your submission':'Submit a fix'}</button></div>`:''}
      ${draft?.error&&!openForm?`<p class="error" role="alert">${escape(draft.error)}</p>`:''}
      ${openForm?submission(item,draft):''}
      ${item.submissions.length?`<details data-history="${item.id}" ${histories.get(item.id)?'open':''}><summary>Recent submission history (${item.submissions.length})</summary>${item.submissions.map(s=>`<div class="history"><strong>Submission ${s.number} · ${s.state==='accepted'?'Accepted':s.state==='sent_back'?'Changes requested':'Awaiting review'}</strong><p><small>${escape(date(s.submittedAt))} · Submitted through this Contractor link</small></p>${s.notes?`<p>${escape(s.notes)}</p>`:''}${s.feedback?`<p class="feedback">${escape(s.feedback)}</p>`:''}</div>`).join('')}</details>`:''}
      </article>`;
  }
  function connection() {
    if (offline) return `<p class="notice connection" role="status"><strong>You are offline.</strong> ${storageReady?'Your notes and photos are kept on this device.':'Keep this page open: your notes and photos are kept here.'} Send them when you have signal again.</p>`;
    return notice ? `<p class="notice success" role="status">${escape(notice)}</p>` : '';
  }
  function render() {
    if (!current) return;
    const y = scrollY, active = document.activeElement, focused = active?.id, start = active?.selectionStart, end = active?.selectionEnd;
    const counts = {work:0,review:0,closed:0};
    current.items.forEach(i=>counts[i.status==='closed'?'closed':i.status==='awaiting_review'?'review':'work']++);
    content.innerHTML = `<div class="intro"><p class="eyebrow">${escape(current.contractorName || 'Shared project snags')}</p><h1>${escape(current.projectName)}</h1>${current.projectAddress?`<p class="project-meta">${escape(current.projectAddress)}</p>`:''}<p class="help">Link expires ${escape(date(current.expiresAt))} · No account needed</p></div>
      ${connection()}
      ${current.mode!=='completion'?`<p class="notice"><strong>${current.mode==='preview'?'Preview · read only':'Read-only Contractor link'}</strong><br>You can view the shared snags. This link cannot submit evidence or change their status.</p>`:''}
      <div class="status-guide" aria-label="Statuses on this page"><span><strong>${counts.work}</strong>Need work</span><span><strong>${counts.review}</strong>Awaiting review</span><span><strong>${counts.closed}</strong>Accepted &amp; closed</span></div>
      <div class="list-tools"><p>${current.total} shared snag${current.total===1?'':'s'}${current.total>25?' · Counts above are for this page':''}</p><button class="secondary" data-refresh ${busy?'disabled':''}>Check for updates</button></div>
      ${pageError?`<p class="error" role="alert">${escape(pageError)}</p>`:''}
      ${current.items.length?current.items.map(card).join(''):'<div class="empty"><h2>No snags to show</h2><p>This link has no current snag assignments. Ask the project manager if you expected work here.</p></div>'}
      ${page>1||current.hasMore?`<nav class="pagination" aria-label="Snag pages"><button class="secondary" data-page="${page-1}" ${page===1||busy?'disabled':''}>Previous</button><span>Page ${page}</span><button class="secondary" data-page="${page+1}" ${!current.hasMore||busy?'disabled':''}>Next</button></nav>`:''}`;
    content.querySelectorAll('.photo-button img').forEach(img => img.addEventListener('error',()=>{ const button = img.closest('button'); if(button){button.disabled=true;button.querySelector('span').textContent='Photo unavailable · check for updates';} }));
    if (focused) { const el = document.getElementById(focused); if(el){el.focus({preventScroll:true}); if(typeof start === 'number' && el.setSelectionRange) el.setSelectionRange(start,end); } }
    scrollTo({top:y,behavior:'instant'});
  }
  function gate(error) {
    const needsPIN = error.identifier === 'pin_required';
    content.innerHTML = `<section class="gate"><p class="eyebrow">Contractor link</p><h1>${needsPIN?'Enter your PIN':error.network?'No connection':'This link is unavailable'}</h1><p>${escape(error.message)}</p>${needsPIN?`<form class="pin-form"><label for="link-pin">PIN from your project manager</label><input id="link-pin" name="pin" type="password" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{4,8}" minlength="4" maxlength="8" required><p class="pin-error" role="alert"></p><button class="primary">Open snag list</button></form>`:error.network?'<button class="secondary" data-refresh>Try again</button>':'<p class="help">Ask the project manager to share a new Contractor link.</p><button class="secondary" data-refresh>Try again</button>'}</section>`;
    const form = content.querySelector('.pin-form');
    form?.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{await request(root+'/verify-pin',{pin:form.elements.pin.value});form.elements.pin.value='';await load();}catch(e){form.querySelector('.pin-error').textContent=e.message;button.disabled=false;}});
  }
  /* Brings back unsent drafts saved on this device for snags shown on this page. A draft
     whose attempt the server already records, or whose snag no longer needs work, is
     deleted instead: the server's state always wins. */
  async function restore() {
    if (!storageReady) return;
    if (stored === null) { await device.purge(); stored = new Map((await device.all()).map(r=>[r.snagId,r])); }
    for (const item of current.items) {
      const record = stored.get(item.id); if (!record || drafts.has(item.id)) continue;
      stored.delete(item.id);
      if (item.submissions.some(s=>s.id===record.intent) || !actionable(item)) { device.remove(item.id); continue; }
      const files = (record.files||[]).filter(f=>f.file instanceof Blob).map(f=>({file:f.file instanceof File ? f.file : new File([f.file],'photo.jpg',{type:f.file.type}),command:f.command||null,ready:Boolean(f.ready)}));
      files.forEach(f=>{f.preview=preview(f.file);});
      drafts.set(item.id,{open:true,restored:true,note:record.note||'',files,intent:record.intent,revision:record.revision,workflowRevision:record.workflowRevision,request:record.request||null,error:''});
    }
  }
  async function load() {
    try {
      const result = await request(root+'?page='+page,undefined,'GET');
      current = result; pageError = '';
      for(const item of current.items){const draft=drafts.get(item.id); if(draft&&item.submissions.some(s=>s.id===draft.intent)) forget(item.id);}
      await restore();
      render();
    } catch(error) {
      if(error.status===403||error.status===404||error.status===410){gate(error);return;}
      if(current){pageError=error.message;render();}else gate(error);
    }
  }
  function draftFor(item) {
    if(!drafts.has(item.id))drafts.set(item.id,{open:false,note:'',files:[],intent:uuid(),revision:item.revision,workflowRevision:item.workflowRevision,error:''});
    return drafts.get(item.id);
  }
  async function processFile(item,draft,file,index,total) {
    if(file.ready)return;
    const label = `Photo ${index+1} of ${total}`;
    const status = text => { file.progress = text; const el = document.getElementById(`upload-${item.id}-${index}`); if (el) el.textContent = text; };
    let bytes;
    if(!file.command){status(`${label} · Preparing…`);bytes=await file.file.arrayBuffer();const sha=hex(await crypto.subtle.digest('SHA-256',bytes));file.command={mutation:meta(),id:uuid(),expectedRevision:draft.revision,purpose:'completion',intentId:draft.intent,sha256:sha,byteCount:bytes.byteLength,mimeType:file.file.type};persist(item.id);}
    status(`${label} · Reserving upload…`);
    await request(`${root}/snags/${item.id}/media`,file.command);
    bytes ||= await file.file.arrayBuffer();
    status(`${label} · Uploading 0%`);
    const result=await upload(`${root}/snags/${item.id}/media/${file.command.id}/content`,bytes,file.file.type,share=>status(share<1?`${label} · Uploading ${Math.round(share*100)}%`:`${label} · Checking photo…`));
    if(result.state!=='ready')throw new Error('This photo is not ready. Try again before submitting.');
    file.ready=true;file.progress='';persist(item.id);render();
  }
  content.addEventListener('toggle',event=>{if(event.target.dataset.history)histories.set(event.target.dataset.history,event.target.open);},true);
  content.addEventListener('input',event=>{const id=event.target.dataset.note;if(id){drafts.get(id).note=event.target.value;persistSoon(id);}});
  content.addEventListener('change',async event=>{
    const id=event.target.dataset.files;if(!id)return;
    const draft=drafts.get(id),chosen=[...event.target.files];draft.error='';draft.preparing=chosen.length;render();
    for(const original of chosen){
      if(draft.files.length>=20){draft.error='Choose up to 20 photos.';break;}
      try{const file=await prepare(original);draft.files.push({file,preview:preview(file)});}
      catch(error){draft.error=error.message;}
      draft.preparing=Math.max(0,draft.preparing-1);
    }
    draft.preparing=0;persist(id);render();
  });
  content.addEventListener('submit',async event=>{
    const id=event.target.dataset.submit;if(!id)return;event.preventDefault();if(busy)return;
    const item=current.items.find(i=>i.id===id),draft=drafts.get(id);
    if(!actionable(item)||draft.revision!==item.revision||draft.workflowRevision!==item.workflowRevision)return;
    if(!draft.files.length){draft.error='Add at least one after photo showing the completed work.';render();return;}
    if(navigator.onLine===false){offline=true;draft.error=interrupted().message;render();return;}
    busy=true;draft.error='';notice='';draft.stage='Uploading photos…';render();
    let sent=false;
    try{for(const [index,file] of draft.files.entries())await processFile(item,draft,file,index,draft.files.length);
      if(!draft.request){draft.request={mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)};persist(id);}
      draft.stage='Sending your fix for review…';render();
      const result=await request(`${root}/snags/${id}/workflow/submit`,draft.request);
      if(result.status!=='awaiting_review')throw new Error('Check the latest snag status before taking further action.');
      forget(id);sent=true;notice=`Your fix for ${item.reference} was sent for review. The manager will check your evidence.`;
    }catch(error){draft.error=error.message;if(error.status===409){await load();}else if(error.identifier==='pin_required'){gate(error);}}
    finally{busy=false;if(drafts.get(id))drafts.get(id).stage='';await load();if(sent)document.getElementById('snag-'+id)?.focus({preventScroll:true});}
  });
  content.addEventListener('click',async event=>{
    const button=event.target.closest('button');if(!button||button.disabled)return;
    if(button.hasAttribute('data-refresh')){await load();return;}
    if(button.dataset.choose){document.getElementById('files-'+button.dataset.choose)?.click();return;}
    if(button.dataset.page){page=Number(button.dataset.page);await load();content.focus();scrollTo({top:0,behavior:'instant'});return;}
    if(button.dataset.photo){const item=current.items.find(i=>i.id===button.dataset.snag),photo=item.photos.find(p=>p.id===button.dataset.photo);const dialog=document.getElementById('photo-viewer'),img=dialog.querySelector('img');img.src=photoURL(item,photo);img.alt=`${photo.label} evidence for ${item.reference} · ${item.title}`;dialog.showModal();return;}
    if(button.dataset.discard){if(busy||!confirm('Discard the unsent notes and photos saved for this snag?'))return;forget(button.dataset.discard);render();return;}
    const id=button.dataset.open||button.dataset.cancel||button.dataset.rebase||button.dataset.start||button.dataset.snag;
    if(!id||busy)return;const item=current.items.find(i=>i.id===id),draft=draftFor(item);
    if(button.dataset.open){draft.open=true;render();document.getElementById('note-'+id)?.focus();}
    if(button.dataset.cancel){draft.open=false;render();document.getElementById('open-'+id)?.focus({preventScroll:true});}
    if(button.dataset.remove!==undefined){release(draft.files.splice(Number(button.dataset.remove),1));persist(id);render();}
    if(button.dataset.rebase&&actionable(item)){draft.revision=item.revision;draft.workflowRevision=item.workflowRevision;draft.request=null;draft.error='';for(const f of draft.files)if(!f.ready)f.command=null;persist(id);render();}
    if(button.dataset.start){busy=true;draft.error='';render();try{if(!draft.startRequest)draft.startRequest={mutation:meta(),expectedRevision:item.revision,expectedWorkflowRevision:item.workflowRevision};const result=await request(`${root}/snags/${id}/workflow/start`,draft.startRequest);draft.startRequest=null;draft.revision=result.revision;draft.workflowRevision=result.workflowRevision;}catch(error){draft.error=error.message;}finally{busy=false;await load();}}
  });
  const dialog=document.getElementById('photo-viewer');dialog.querySelector('button').addEventListener('click',()=>dialog.close());dialog.addEventListener('close',()=>dialog.querySelector('img').removeAttribute('src'));
  addEventListener('offline',()=>{offline=true;render();});
  addEventListener('online',()=>{offline=false;notice=[...drafts.values()].some(d=>d.note||d.files.length)?'You are back online. Check your photos below and send your fix.':'';render();if(!busy)load();});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'){for(const id of drafts.keys())persist(id);}else if(!busy&&current)load();});
  addEventListener('pagehide',()=>{for(const id of drafts.keys())persist(id);});
  addEventListener('beforeunload',event=>{if(busy||(!storageReady&&[...drafts.values()].some(d=>d.note||d.files.length))){event.preventDefault();event.returnValue='';}});
  (async()=>{try{storageReady=await device.ready();if(storageReady)deviceId=(await device.deviceId())||deviceId;}catch{storageReady=false;}load();})();
})();
