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
  /* At most this many photos upload at once (1 = one after another). The server checks one photo at a time
     and every photo keeps its own retry identity, so a second upload in flight only overlaps waiting. */
  const IN_FLIGHT = 2;
  const uuid = () => crypto.randomUUID();
  /* The server spells ids in upper case (Swift's UUID); this page mints them in lower case. Ids are compared through these. */
  const low = value => String(value ?? '').toLowerCase();
  const same = (a,b) => a != null && b != null && low(a) === low(b);
  let current, page = 1, busy = false, pageError = '', notice = '', offline = navigator.onLine === false, storageReady = false;
  let deviceId = uuid();
  let stored = null;
  const meta = () => ({operationId:uuid(),deviceId:deviceId});
  /* WP4, staging-only switch: photos upload as they are added. On only when the server says so (`earlyUpload`, which is true
     only where RUNTIME_DIAGNOSTICS is enabled - never in production) and the address does not carry #wp4=off (the harness's
     A/B). Off, the page uploads at Submit exactly as before. */
  const early = () => current?.earlyUpload === true && !/(^|[#&])wp4=off(&|$)/.test(location.hash);
  const RETRY_DELAYS = [2000,5000];
  const ACTIVE = ['preparing','allocating','uploading','checking'];
  let inFlight = 0, pinGate = false;
  /* Identities with an allocate or PUT still out (id -> snag), and identities the server has confirmed retired. A retirement
     that races its own allocation (404 while the allocate is out) is kept and sent again once that answer is in. */
  const sending = new Map(), retiredIds = new Set();
  /* A discarded draft's intent is remembered so a reload retires any of its uploads that landed late; for at least this long. */
  const RETIRED_INTENT_MS = 120000;
  /* One persistent live region for upload and send announcements (the list itself is re-drawn, so it cannot carry them). */
  const announcer = (() => { const el = document.createElement('p'); el.setAttribute('role','status'); el.setAttribute('aria-live','polite');
    el.style.cssText = 'position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0';
    document.body.appendChild(el); return el; })();
  const announce = text => { announcer.textContent = ''; setTimeout(() => { announcer.textContent = text; }, 60); };
  const isStale = (item,draft) => draft.revision !== item.revision || draft.workflowRevision !== item.workflowRevision;
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
  /* Returns when the record is written (or storage is unavailable): a new retry identity and a frozen request are saved
     before the network call that uses them (WP4 4.7). */
  function persistNow(id) {
    const draft = drafts.get(id); if (!draft || !storageReady) return Promise.resolve(false);
    if (!(draft.note || draft.files.length || draft.request || draft.toRetire?.length || draft.retiredIntents?.length)) { device.remove(id); return Promise.resolve(true); }
    return device.put(id,{note:draft.note,intent:draft.intent,revision:draft.revision,workflowRevision:draft.workflowRevision,request:draft.request||null,
      requestSent:Boolean(draft.requestSent),submitRequested:Boolean(draft.submitRequested),tombstones:[...(draft.tombstones||[])],toRetire:draft.toRetire||[],retiredIntents:draft.retiredIntents||[],
      linkExpiresAt:current?.expiresAt||null,files:draft.files.map(f=>({file:f.file,command:f.command||null,ready:Boolean(f.ready)}))});
  }
  function persist(id) { persistNow(id); }
  const persistSoon = (() => { const timers = new Map(); return id => { clearTimeout(timers.get(id)); timers.set(id,setTimeout(()=>persist(id),400)); }; })();
  const preview = file => { try { return URL.createObjectURL(file); } catch { return ''; } };
  const release = files => files.forEach(f => { if (f.preview) URL.revokeObjectURL(f.preview); });
  function forget(id) { const draft = drafts.get(id); if (draft) release(draft.files); drafts.delete(id); device.remove(id); }
  /* A draft the server has accepted is forgotten; retirements it still owed (removed photos) are kept in a holder and sent. */
  function forgetSent(id) { const owed = drafts.get(id)?.toRetire || []; forget(id); for (const a of owed) queueRetire(id,a); if (owed.length && early()) drainRetirements(id); }

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
  function upload(path, bytes, mime, progress, started) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest(); if (started) started(xhr);
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
  /* Card photos are fetched once each, only when their card is near the screen, two at a time, and never while this
     page is sending a submission: the contractor's own upload goes first. Each is kept as a blob: URL so re-drawing the
     list does not download it again (the server marks photos no-store). */
  const photoBlobs = new Map(), photoState = new Map(); let photoActive = 0;
  const photoObserver = 'IntersectionObserver' in window ? new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) { photoObserver.unobserve(entry.target); wantPhoto(entry.target.dataset.src); }
  }, {rootMargin:'300px 0px'}) : null;
  function wantPhoto(url) { if (!photoBlobs.has(url) && !photoState.has(url)) photoState.set(url,'queued'); pumpPhotos(); }
  function pumpPhotos() {
    if (busy || inFlight > 0) return;
    for (const [url,state] of photoState) {
      if (photoActive >= 2) return;
      if (state !== 'queued') continue;
      photoState.set(url,'loading'); photoActive++;
      fetch(url,{credentials:'same-origin',cache:'no-store',priority:'low'})
        .then(r => r.ok ? r.blob() : Promise.reject(new Error(String(r.status))))
        .then(blob => { photoBlobs.set(url,URL.createObjectURL(blob)); photoState.delete(url); }, () => { photoState.set(url,'failed'); })
        .finally(() => { photoActive--; showPhotos(url); pumpPhotos(); });
    }
  }
  function photoUnavailable(img) { const button = img.closest('button'); if(button){button.disabled=true;button.querySelector('span').textContent='Photo unavailable · check for updates';} }
  function showPhotos(only) {
    content.querySelectorAll('.photo-button img[data-src]').forEach(img => {
      const url = img.dataset.src; if (only && url !== only) return;
      if (photoBlobs.has(url)) { if (img.getAttribute('src') !== photoBlobs.get(url)) img.src = photoBlobs.get(url); }
      else if (photoState.get(url) === 'failed') photoUnavailable(img);
      else if (!only) { if (photoObserver) photoObserver.observe(img); else wantPhoto(url); }
    });
  }
  function renderPhotos(item) {
    if (!item.photos.length) return '<p class="empty-photo">No shared photos for this snag.</p>';
    return `<div class="photo-grid">${item.photos.map(p => `<button class="photo-button" data-photo="${p.id}" data-snag="${item.id}" aria-label="Enlarge ${escape(p.label.toLowerCase())} photo for ${escape(item.reference)}"><img data-src="${photoURL(item,p)}" alt="${escape(p.label)} evidence for ${escape(item.title)}" decoding="async"><span>${escape(p.label)} photo · Enlarge</span></button>`).join('')}</div>`;
  }
  function fileState(file,i,n) {
    if (!early()) {
      if (file.ready) return 'Uploaded and checked';
      return file.progress || (file.command ? 'Not sent yet · will retry' : 'Ready to upload');
    }
    const label = `Photo ${i+1} of ${n}`;
    switch (file.status) {
      case 'ready': return 'Uploaded and checked';
      case 'preparing': return `${label} · Preparing…`;
      case 'allocating': return `${label} · Reserving upload…`;
      case 'uploading': return `${label} · Uploading ${Math.round((file.share||0)*100)}%`;
      case 'checking': return `${label} · Checking and storing photo…`;
      case 'retrying': return `${label} · Retrying…`;
      case 'failed': return `Not uploaded: ${file.error || 'this photo could not be uploaded.'}`;
      default: return file.waitingForSignal ? `${label} · Waiting for signal` : `${label} · Waiting to upload`;
    }
  }
  function submission(item,draft) {
    const stale = isStale(item,draft), wp4 = early();
    /* WP4: the note stays editable until the final request is sent; uploads never lock it. Adding photos stops once Submit
       is pressed (Remove stays, and un-freezes the unsent request). */
    const locked = wp4 ? (busy || Boolean(draft.requestSent) || stale) : (busy || Boolean(draft.request) || stale);
    const adding = wp4 ? (locked || Boolean(draft.submitRequested)) : locked;
    const ready = draft.files.filter(f=>f.ready).length, uploading = draft.files.some(f=>ACTIVE.includes(f.status)||f.status==='retrying');
    const remaining = draft.files.length - ready;
    const submitLabel = busy ? (draft.stage||'Sending your fix…') : wp4 && draft.submitRequested && remaining === 0 ? 'Sending your fix for review…' : wp4 && draft.submitRequested ? `Sending when photos finish · ${ready} of ${draft.files.length} uploaded` : draft.request && (!wp4 || draft.requestSent) ? 'Retry submission' : 'Submit for review';
    return `<form class="submission" data-submit="${item.id}">
      <h3>Submit your fix for review</h3><p class="help">Add after photos showing the completed work. The manager will review your evidence before this snag is closed.</p>
      ${draft.restored?`<p class="notice restored">Restored from this device: the notes and photos you had not sent yet. <button type="button" class="link-button" data-discard="${item.id}" ${busy?'disabled':''}>Discard them</button></p>`:''}
      ${stale ? `<div class="notice">The snag has changed since you started. Check the current details and feedback above. Your notes and photos are retained.<div class="actions"><button type="button" class="secondary" data-rebase="${item.id}" ${busy?'disabled':''}>I have reviewed the latest details</button></div></div>`:''}
      <label for="note-${item.id}">What did you fix?</label><textarea id="note-${item.id}" data-note="${item.id}" maxlength="10000" ${locked?'readonly':''} placeholder="Describe the repair and any checks you carried out">${escape(draft.note)}</textarea>
      <p class="field-label">After photos <span class="help">(required)</span></p>${wp4?`<p class="help disclosure"><strong>Photos upload as you add them. Shared with the project team when you submit.</strong><br>JPEG or PNG, up to 20 photos. Larger camera photos are resized to fit 10 MB.</p>`:'<p class="help">JPEG or PNG. Larger camera photos are resized to fit 10 MB. Up to 20 photos.</p>'}
      <button type="button" class="secondary" data-choose="${item.id}" aria-describedby="terms-${item.id}" ${adding||draft.preparing?'disabled':''}>Add after photos</button>
      <input id="files-${item.id}" data-files="${item.id}" type="file" accept="image/jpeg,image/png" multiple hidden tabindex="-1" aria-hidden="true" ${adding?'disabled':''}>
      ${draft.preparing?`<p class="help" role="status">Preparing ${draft.preparing} photo${draft.preparing===1?'':'s'}…</p>`:''}
      <div class="upload-list">${draft.files.map((file,i) => `<div class="upload-file">${file.preview?`<img class="upload-thumb" src="${file.preview}" alt="">`:''}<span class="upload-name">${escape(file.file.name)}<br><span class="help${file.ready?' done':''}${file.status==='failed'?' error':''}" id="upload-${file.key}">${escape(fileState(file,i,draft.files.length))}</span></span>${wp4&&file.status==='failed'?`<button class="secondary" type="button" data-retry-file="${file.key}" data-snag="${item.id}" ${busy?'disabled':''}>Try again</button>`:''}<button class="secondary" type="button" data-remove="${file.key}" data-snag="${item.id}" ${(wp4?(busy||draft.requestSent):locked)?'disabled':''}>Remove</button></div>`).join('')}</div>
      ${draft.files.length?`<p class="help" aria-live="polite">${ready} of ${draft.files.length} photo${draft.files.length===1?'':'s'} uploaded${storageReady?' · Unsent work is kept on this device':''}</p>`:''}
      <p class="help terms-notice" id="terms-${item.id}">Your photos and notes will be shared with the project team and may appear in project reports. Upload only information you have permission to share. By submitting, you agree to the <a href="https://usesnaglist.com/terms#contractor-links" target="_blank" rel="noopener noreferrer" aria-label="Contractor link terms (opens in a new tab)">Contractor link terms</a>. Read our <a href="https://usesnaglist.com/privacy" target="_blank" rel="noopener noreferrer" aria-label="privacy notice (opens in a new tab)">privacy notice</a> to understand how your information is used.</p>
      ${draft.error?`<p class="error" role="alert">${escape(draft.error)}</p>`:''}
      <div class="actions"><button type="submit" class="primary" aria-describedby="terms-${item.id}" ${busy||stale||draft.preparing||(wp4&&draft.submitRequested)?'disabled':''}>${escape(submitLabel)}</button>${wp4&&draft.submitRequested&&!busy&&remaining?`<button type="button" class="secondary" data-cancel-send="${item.id}">Don’t send yet</button>`:''}<button type="button" class="secondary" data-cancel="${item.id}" ${busy?'disabled':''}>Back to snag</button></div>
      ${wp4&&draft.submitRequested&&remaining?`<p class="help" role="status">Your fix will be sent when ${remaining===1?'the last photo finishes':`the remaining ${remaining} photos finish`} uploading. Nothing has been sent yet.</p>`:''}
      <p class="help">${wp4&&!storageReady?'Keep this page open until your fix is sent: this browser is not keeping unsent notes and photos.':wp4?(uploading||draft.submitRequested?'Keep this page open until your photos finish uploading. Unsent notes and photos stay on this device for 7 days.':'You can leave this page: unsent notes and photos stay on this device for 7 days. Uploaded photos are kept privately for 24 hours and are sent again after that.'):storageReady?'You can leave this page: unsent notes and photos stay on this device for 7 days.':'Keep this page open while your photos upload.'} We’ll confirm when your fix has been sent for review.</p></form>`;
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
    content.querySelectorAll('.photo-button img').forEach(img => img.addEventListener('error',()=>photoUnavailable(img)));
    showPhotos();
    if (focused) { const el = document.getElementById(focused); if(el){el.focus({preventScroll:true}); if(typeof start === 'number' && el.setSelectionRange) el.setSelectionRange(start,end); } }
    scrollTo({top:y,behavior:'instant'});
  }
  function gate(error) {
    const needsPIN = error.identifier === 'pin_required';
    content.innerHTML = `<section class="gate">${notice?`<p class="notice success" role="status">${escape(notice)}</p>`:''}<p class="eyebrow">Contractor link</p><h1>${needsPIN?'Enter your PIN':error.network?'No connection':'This link is unavailable'}</h1><p>${escape(error.message)}</p>${needsPIN?`<form class="pin-form"><label for="link-pin">PIN from your project manager</label><input id="link-pin" name="pin" type="password" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{4,8}" minlength="4" maxlength="8" required><p class="pin-error" role="alert"></p><button class="primary">Open snag list</button></form>`:error.network?'<button class="secondary" data-refresh>Try again</button>':'<p class="help">Ask the project manager to share a new Contractor link.</p><button class="secondary" data-refresh>Try again</button>'}</section>`;
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
      if (item.submissions.some(s=>same(s.id,record.intent)) || !actionable(item)) { device.remove(item.id); for (const a of record.toRetire||[]) queueRetire(item.id,a); continue; }
      const files = (record.files||[]).filter(f=>f.file instanceof Blob).map(f=>({file:f.file instanceof File ? f.file : new File([f.file],'photo.jpg',{type:f.file.type}),command:f.command||null,ready:Boolean(f.ready)}));
      /* WP4: a stored "ready" is a hint; the server's own record decides (reconcile) before Submit can rely on it. */
      files.forEach(f=>{f.preview=preview(f.file);f.key=uuid();f.status='queued';f.restoredCommand=Boolean(f.command);if(early()){f.ready=false;}});
      /* A record holding only retirements (a discarded draft whose uploads are still being retired) is not a draft to show. */
      const shown = Boolean(record.note || files.length || record.request);
      drafts.set(item.id,{open:shown,restored:shown,note:record.note||'',files,intent:record.intent,revision:record.revision,workflowRevision:record.workflowRevision,request:record.request||null,
        requestSent:Boolean(record.requestSent),submitRequested:Boolean(record.submitRequested),tombstones:new Set(record.tombstones||[]),toRetire:record.toRetire||[],
        retiredIntents:record.retiredIntents||[],error:''});
    }
  }
  async function load() {
    try {
      const result = await request(root+'?page='+page,undefined,'GET');
      current = result; pageError = '';
      for (const [url,state] of photoState) if (state === 'failed') photoState.delete(url);
      for(const item of current.items){const draft=drafts.get(item.id); if(draft&&item.submissions.some(s=>same(s.id,draft.intent))) forgetSent(item.id);}
      await restore();
      pinGate = false;
      if (early()) { for (const item of current.items) reconcile(item); }
      render();
      if (early()) { pump(); drainRetirements(); for (const id of drafts.keys()) maybeSend(id); }
    } catch(error) {
      if(error.status===403||error.status===404||error.status===410){gate(error);return;}
      if(current){pageError=error.message;render();}else gate(error);
    }
  }
  function draftFor(item) {
    if(!drafts.has(item.id))drafts.set(item.id,{open:false,note:'',files:[],intent:uuid(),revision:item.revision,workflowRevision:item.workflowRevision,error:'',tombstones:new Set(),toRetire:[],retiredIntents:[]});
    return drafts.get(item.id);
  }
  async function processFile(item,draft,file,index,total) {
    if(file.ready)return;
    const label = `Photo ${index+1} of ${total}`;
    const status = text => { file.progress = text; const el = document.getElementById(`upload-${file.key}`); if (el) el.textContent = text; };
    let bytes;
    if(!file.command){status(`${label} · Preparing…`);bytes=await file.file.arrayBuffer();const sha=hex(await crypto.subtle.digest('SHA-256',bytes));file.command={mutation:meta(),id:uuid(),expectedRevision:draft.revision,purpose:'completion',intentId:draft.intent,sha256:sha,byteCount:bytes.byteLength,mimeType:file.file.type};persist(item.id);}
    status(`${label} · Reserving upload…`);
    await request(`${root}/snags/${item.id}/media`,file.command);
    bytes ||= await file.file.arrayBuffer();
    status(`${label} · Uploading 0%`);
    const result=await upload(`${root}/snags/${item.id}/media/${file.command.id}/content`,bytes,file.file.type,share=>status(share<1?`${label} · Uploading ${Math.round(share*100)}%`:`${label} · Checking and storing photo…`));
    if(result.state!=='ready')throw new Error('This photo is not ready. Try again before submitting.');
    file.ready=true;file.progress='';draft.stage=`Uploading photos… ${draft.files.filter(f=>f.ready).length} of ${total} sent`;persist(item.id);render();
  }
  /* Uploads every photo that is not yet ready, at most IN_FLIGHT at a time, taking them in list order.
     The first failure wins: no further photo starts, and every upload already in flight is awaited before
     this returns, so no late answer can change the draft after the submit handler has finished. Photos
     that did finish stay ready, so a retry resumes with the rest. */
  async function uploadAll(item,draft) {
    const total=draft.files.length; let next=0, failure=null;
    const worker=async()=>{
      while(failure===null){
        const index=next++; if(index>=total)return;
        const file=draft.files[index]; if(file.ready)continue;
        try{await processFile(item,draft,file,index,total);}catch(error){if(failure===null)failure=error;return;}
      }
    };
    await Promise.all(Array.from({length:Math.max(1,Math.min(IN_FLIGHT,total))},worker));
    if(failure!==null)throw failure;
  }
  /* ---- WP4 (staging-only switch): the upload queue (FABLE-DESIGN-A-AMENDMENT §4.1-4.9) ----
     Each photo: queued -> preparing (hash) -> allocating -> uploading n% -> checking -> ready, or retrying / failed / removed.
     At most IN_FLIGHT photos upload at once across the page; the server still checks one photo at a time. `busy` covers only
     the final send. Every retry reuses the photo's persisted command (same asset id and operation); a photo that was removed
     is tombstoned, so a late answer for it changes nothing; its server upload is retired. */
  const gone = (id,draft,f) => drafts.get(id) !== draft || !draft.files.includes(f) || Boolean(f.command && draft.tombstones?.has(low(f.command.id)));
  function updateLine(draft,f) {
    const el = document.getElementById('upload-'+f.key);
    if (el) el.textContent = fileState(f,draft.files.indexOf(f),draft.files.length);
  }
  /* Reads the chosen photo. A read that fails (H113 W5: WebKit could not read the file while offline) is treated like a lost
     connection - waited for, retried, resumed when the browser is back online - never as a refusal: nothing reached the server. */
  async function readBytes(f) {
    try { return await f.file.arrayBuffer(); }
    catch { throw Object.assign(new Error('This photo could not be read on this device. Try again, or remove it and add it again.'),{readFailed:true}); }
  }
  /* The photo's identity: minted once, saved before it is used, reused by every retry. */
  function ensureCommand(id,draft,f) {
    if (f.command) return Promise.resolve();
    return f.commandPromise ||= (async () => {
      const bytes = await readBytes(f), sha = hex(await crypto.subtle.digest('SHA-256',bytes));
      if (!f.command) f.command = {mutation:meta(),id:uuid(),expectedRevision:draft.revision,purpose:'completion',intentId:draft.intent,sha256:sha,byteCount:bytes.byteLength,mimeType:f.file.type};
      await persistNow(id);
    })().finally(() => { f.commandPromise = null; });
  }
  /* Queues the retirement of one of this link's uploads for a snag. A snag whose draft is gone (sent, discarded, tidied) gets an
     empty holder, so a late answer for a photo the page no longer wants is still retired (§4.4). */
  function queueRetire(id,assetId) {
    let draft = drafts.get(id);
    if (!draft) { const item = current?.items.find(i=>i.id===id); draft = {open:false,note:'',files:[],intent:uuid(),revision:item?.revision,workflowRevision:item?.workflowRevision,error:'',tombstones:new Set(),toRetire:[],retiredIntents:[]}; drafts.set(id,draft); }
    const key = low(assetId); draft.tombstones?.add(key);
    draft.toRetire ||= []; if (!draft.toRetire.includes(key)) draft.toRetire.push(key);
  }
  /* Forgets a draft that holds nothing any more: no note, photos, request, pending retirement, remembered discarded intent or
     upload still out. */
  function tidy(id) {
    const d = drafts.get(id);
    if (!d || d.open || d.note || d.files.length || d.request || (d.toRetire||[]).length || (d.retiredIntents||[]).length || d.draining || [...sending.values()].includes(id)) return false;
    forget(id); return true;
  }
  /* Retires this link's unattached uploads that the page no longer wants, through DELETE …/media/:id. Offline (or behind the PIN
     gate) they stay listed and go on the next drain; a 404 for an identity whose allocate is still out is sent again when that
     answer is in; any other refusal ends it (an attached upload belongs to a submission; a lapsed link leaves it to expiry). */
  async function drainRetirements(only) {
    for (const [id,draft] of [...drafts]) {
      if (only && id !== only) continue;
      if (draft.draining) { draft.drainAgain = true; continue; }
      if (!(draft.toRetire||[]).length) { tidy(id); continue; }
      draft.draining = true;
      try {
        do {
          draft.drainAgain = false;
          for (const assetId of [...(draft.toRetire||[])]) {
            try { await request(`${root}/snags/${id}/media/${assetId}`,undefined,'DELETE'); retiredIds.add(assetId); }
            catch (error) {
              if (error.network || error.identifier === 'pin_required') continue;
              if (error.status === 404 && sending.has(assetId)) continue;
            }
            draft.toRetire = (draft.toRetire||[]).filter(x => x !== assetId);
          }
        } while (draft.drainAgain);
      } finally { draft.draining = false; }
      if (drafts.get(id) === draft && !tidy(id)) persist(id);
    }
  }
  /* A new identity for a photo whose upload the server has expired, retired or erased (same intent, same file). */
  function remint(id,draft,f,retireOld) {
    if (f.command) { draft.tombstones.add(low(f.command.id)); if (retireOld) queueRetire(id,f.command.id); }
    if (f.command) f.command = {...f.command,mutation:meta(),id:uuid(),expectedRevision:draft.revision};
    f.ready = false; f.status = 'queued'; f.attempts = 0; f.allocated = false; f.restoredCommand = false;
    if (draft.request && !draft.requestSent) draft.request = {...draft.request,mutation:meta(),evidenceIds:draft.files.map(x=>x.command?.id)};
  }
  /* Server state wins (§4.6): `drafts` lists this link's own unattached, unretired uploads (ids in upper case).
     - A local photo whose upload is listed ready, unexpired and with the same digest is done; listed allocated, it is sent again
       under the same identity; listed but expired, in another state or with another digest, it gets a new identity and the old
       upload is retired.
     - A local photo whose identity is not listed is sent again under the same identity: allocation is idempotent, so an
       allocation that landed after the list was read is adopted, and one the server retired or erased is renewed by
       uploadFailed (410). It is never re-minted on absence alone (H111: that left the first upload behind).
     - A listed upload no local photo holds is retired when this device knows it abandoned it: its intent was discarded here,
       its identity was removed or replaced here, or it duplicates (same digest, same intent) a photo held under another
       identity. Any other unheld upload — another device's, another tab's, or a draft this browser never kept — is left to
       the expiry cleanup: unattachable 24 h after allocation, retired and fenced by the hourly pass 7 days after that. */
  function reconcile(item) {
    const draft = drafts.get(item.id); if (!draft) return;
    const list = Array.isArray(item.drafts) ? item.drafts : null;
    const server = list ? new Map(list.map(d=>[low(d.id),d])) : null, now = Date.now();
    for (const f of draft.files) {
      if (f.verified || ACTIVE.includes(f.status) || f.status === 'retrying' || f.status === 'failed') continue;
      if (!f.command || !server) { f.ready = false; f.status = 'queued'; continue; }
      const d = server.get(low(f.command.id)), fresh = d && Date.parse(d.expiresAt) > now;
      if (!d) { f.ready = false; f.status = 'queued'; }
      else if (fresh && d.state === 'ready' && same(d.sha256,f.command.sha256)) { f.ready = true; f.verified = true; f.status = 'ready'; }
      else if (fresh && d.state === 'allocated' && same(d.sha256,f.command.sha256)) { f.ready = false; f.status = 'queued'; }
      else remint(item.id,draft,f,true);
    }
    if (!list) return;
    const held = new Set([...draft.files.map(f=>low(f.command?.id)), ...(draft.request?.evidenceIds||[]).map(low)].filter(Boolean));
    const shas = new Set(draft.files.map(f=>low(f.command?.sha256)).filter(Boolean));
    const discarded = new Set((draft.retiredIntents||[]).map(r=>low(r.id)));
    for (const d of list) {
      const key = low(d.id); if (held.has(key)) continue;
      if (discarded.has(low(d.intentId)) || draft.tombstones?.has(key) || (same(d.intentId,draft.intent) && shas.has(low(d.sha256)))) queueRetire(item.id,key);
    }
    draft.retiredIntents = (draft.retiredIntents||[]).filter(r => now - r.at < RETIRED_INTENT_MS || list.some(d=>same(d.intentId,r.id)));
  }
  function pump() {
    if (!early() || !current || pinGate || navigator.onLine === false) return;
    for (const item of current.items) {
      const draft = drafts.get(item.id);
      if (!draft || !actionable(item) || isStale(item,draft)) continue;
      for (const f of draft.files) {
        if (inFlight >= IN_FLIGHT) return;
        if (!f.ready && f.status === 'queued' && !f.waitingForSignal) startUpload(item,draft,f);
      }
    }
  }
  async function startUpload(item,draft,f) {
    inFlight++; f.status = 'preparing'; f.error = ''; updateLine(draft,f);
    let sent = null;
    try {
      await ensureCommand(item.id,draft,f);
      if (gone(item.id,draft,f)) return;
      f.status = 'allocating'; updateLine(draft,f);
      sent = low(f.command.id); sending.set(sent,item.id);
      await request(`${root}/snags/${item.id}/media`,f.command);
      f.allocated = true;
      if (gone(item.id,draft,f)) return;
      const bytes = await readBytes(f);
      f.status = 'uploading'; f.share = 0; updateLine(draft,f);
      const result = await upload(`${root}/snags/${item.id}/media/${f.command.id}/content`,bytes,f.file.type,
        share => { if (gone(item.id,draft,f)) return; f.share = share; f.status = share < 1 ? 'uploading' : 'checking'; updateLine(draft,f); },
        xhr => { f.xhr = xhr; });
      if (gone(item.id,draft,f)) return;
      if (result.state !== 'ready') throw Object.assign(new Error('This photo is not ready yet.'),{status:503,identifier:'media_unavailable'});
      f.ready = true; f.verified = true; f.status = 'ready'; f.attempts = 0;
      await persistNow(item.id);
      announce(`Photo ${draft.files.indexOf(f)+1} of ${draft.files.length} uploaded`);
    } catch (error) {
      if (!gone(item.id,draft,f)) uploadFailed(item,draft,f,error);
    } finally {
      inFlight--; f.xhr = null;
      /* Removed or discarded while its allocate or PUT was out: whatever the server made of it is retired now (H111 W3). */
      if (sent) { sending.delete(sent); if (gone(item.id,draft,f) && !retiredIds.has(sent)) { queueRetire(item.id,sent); drainRetirements(item.id); } }
      if (!busy) render();
      pump(); maybeSend(item.id);
      if (inFlight === 0) pumpPhotos();
    }
  }
  /* Retry policy (R1 as queue policy, Fable §2.2): the same command again, at most twice (2 s, then 5 s), for the app's own
     503 (`media_unavailable`, `workspace_busy`), an edge answer without a body, a connection lost while online, or a failed read
     of the photo on this device. Never a 4xx. Offline, the photo waits for signal; one that failed for want of a connection or a
     read resumes by itself when the browser is back online. An upload the server expired, retired or erased gets a new
     identity; a PIN request pauses the queue at the gate. */
  function uploadFailed(item,draft,f,error) {
    const status = error.status, id = error.identifier, n = draft.files.indexOf(f)+1;
    if (id === 'pin_required') { f.status = 'queued'; pinGate = true; gate(error); return; }
    const transient = Boolean(error.network || error.readFailed);
    if (transient && navigator.onLine === false) { f.status = 'queued'; f.waitingForSignal = true; return; }
    if (status === 409 && (id === 'revision_conflict' || id === 'workflow_conflict')) { f.status = 'queued'; load(); return; }
    const renew = (status === 410 && (id === 'media_erased' || id === 'media_reallocate' || /expired|retired/i.test(error.message||''))) || (status === 409 && id === 'media_key_conflict');
    if (renew && (f.renewals||0) < 2) { f.renewals = (f.renewals||0) + 1; remint(item.id,draft,f,true); persist(item.id); drainRetirements(item.id); return; }
    const retryable = transient || (status === 503 && (id === 'media_unavailable' || id === 'workspace_busy'));
    if (retryable && (f.attempts||0) < RETRY_DELAYS.length) {
      const delay = RETRY_DELAYS[f.attempts||0]; f.attempts = (f.attempts||0) + 1; f.status = 'retrying';
      announce(`Retrying photo ${n} of ${draft.files.length}`);
      f.retryTimer = setTimeout(() => { f.retryTimer = null; if (!gone(item.id,draft,f) && f.status === 'retrying') { f.status = 'queued'; pump(); } }, delay);
      return;
    }
    f.status = 'failed'; f.attempts = 0; f.networkFailed = transient; f.error = error.message || 'This photo could not be uploaded.';
    announce(`Photo ${n} of ${draft.files.length} was not uploaded. ${f.error}`);
    if (draft.submitRequested && !draft.requestSent) {
      draft.submitRequested = false; draft.request = null;
      draft.error = 'Nothing was sent: a photo could not be uploaded. Try it again or remove it, then press Submit again.';
      persist(item.id);
    }
  }
  /* Sends the frozen request once every photo in it is ready (§4.8). Success is shown only on the server's answer. */
  async function maybeSend(id) {
    const draft = drafts.get(id), item = current?.items.find(i=>i.id===id);
    if (!early() || !draft || !item || !draft.submitRequested || busy || pinGate) return;
    if (!draft.files.length || draft.files.some(f=>!f.ready)) return;
    if (!actionable(item) || isStale(item,draft)) { draft.submitRequested = false; render(); return; }
    await sendFinal(item,draft);
  }
  async function sendFinal(item,draft) {
    const id = item.id;
    busy = true; draft.error = ''; notice = ''; draft.stage = 'Sending your fix for review…';
    if (!draft.request) draft.request = {mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)};
    draft.requestSent = true; draft.submitRequested = false;
    await persistNow(id); render(); announce('Sending your fix for review');
    let sent = false;
    try {
      const result = await request(`${root}/snags/${id}/workflow/submit`,draft.request);
      if (result.status !== 'awaiting_review') throw new Error('Check the latest snag status before taking further action.');
      Object.assign(item,{status:result.status,revision:result.revision,workflowRevision:result.workflowRevision});
      forgetSent(id); sent = true; notice = `Your fix for ${item.reference} was sent for review. The manager will check your evidence.`;
      announce(notice);
    } catch (error) {
      draft.error = error.message;
      /* Lost or server-side failures keep the same body: a repeat is answered from the server's receipt. A refusal means nothing
         was committed: the request is discarded and the next Submit freezes a new one. */
      if (!error.network && error.status && error.status < 500) { draft.request = null; draft.requestSent = false; }
      persist(id);
      if (error.status === 409) { await load(); }
      else if (error.identifier === 'pin_required') { pinGate = true; gate(error); }
    } finally {
      busy = false; if (drafts.get(id)) drafts.get(id).stage = '';
      if (sent) { render(); document.getElementById('snag-'+id)?.focus({preventScroll:true}); load(); }
      else render();
      pumpPhotos();
    }
  }
  async function removeFile(item,draft,f) {
    if (f.retryTimer) { clearTimeout(f.retryTimer); f.retryTimer = null; }
    if (f.xhr) { try { f.xhr.abort(); } catch {} }
    if (f.command) { draft.tombstones.add(low(f.command.id)); queueRetire(item.id,f.command.id); }
    f.status = 'removed'; release([f]); draft.files.splice(draft.files.indexOf(f),1);
    if (draft.request && !draft.requestSent) { draft.request = null; draft.submitRequested = false; }
    await persistNow(item.id); render(); announce('Photo removed');
    drainRetirements(item.id);
  }
  /* Discard (§4.4): every upload of this draft is retired at once through the retire route — each photo's identity, and every
     upload the server last listed under this draft's intent that no photo holds (one a reload left behind). An allocate or PUT
     still out is retired when its answer comes in; offline, the retirements wait on this device. The intent is remembered for
     a while so a reload retires any of its uploads that land later; then the page re-reads the list to check. */
  async function discardDraft(id) {
    const draft = drafts.get(id); if (!draft) return;
    const item = current?.items.find(i=>i.id===id);
    for (const f of draft.files) {
      if (f.retryTimer) clearTimeout(f.retryTimer);
      if (f.xhr) { try { f.xhr.abort(); } catch {} }
      if (f.command) { draft.tombstones.add(low(f.command.id)); queueRetire(id,f.command.id); }
      f.status = 'removed';
    }
    for (const d of item?.drafts||[]) if (same(d.intentId,draft.intent)) queueRetire(id,d.id);
    release(draft.files);
    const retiredIntents = [...(draft.retiredIntents||[]).filter(r=>!same(r.id,draft.intent)),{id:low(draft.intent),at:Date.now()}];
    drafts.set(id,{open:false,note:'',files:[],intent:uuid(),revision:draft.revision,workflowRevision:draft.workflowRevision,error:'',
      tombstones:new Set(draft.tombstones),toRetire:draft.toRetire||[],retiredIntents});
    await persistNow(id); render();
    await drainRetirements(id);
    if (!busy && navigator.onLine !== false) await load();
  }
  content.addEventListener('toggle',event=>{if(event.target.dataset.history)histories.set(event.target.dataset.history,event.target.open);},true);
  content.addEventListener('input',event=>{const id=event.target.dataset.note;if(id){const draft=drafts.get(id);draft.note=event.target.value;
    if(early()&&draft.request&&!draft.requestSent){draft.request={...draft.request,mutation:meta(),notes:draft.note};}
    persistSoon(id);}});
  content.addEventListener('change',async event=>{
    const id=event.target.dataset.files;if(!id)return;
    const draft=drafts.get(id),chosen=[...event.target.files];draft.error='';draft.preparing=chosen.length;render();
    for(const original of chosen){
      if(draft.files.length>=20){draft.error='Choose up to 20 photos.';break;}
      try{const file=await prepare(original);draft.files.push({file,preview:preview(file),key:uuid(),status:'queued'});if(early()){persist(id);render();pump();}}
      catch(error){draft.error=error.message;}
      draft.preparing=Math.max(0,draft.preparing-1);
    }
    draft.preparing=0;persist(id);render();pump();
  });
  content.addEventListener('submit',async event=>{
    const id=event.target.dataset.submit;if(!id)return;event.preventDefault();if(busy)return;
    const item=current.items.find(i=>i.id===id),draft=drafts.get(id);
    if(!actionable(item)||draft.revision!==item.revision||draft.workflowRevision!==item.workflowRevision)return;
    if(!draft.files.length){draft.error='Add at least one after photo showing the completed work.';render();return;}
    if(early()){
      if(draft.files.some(f=>f.status==='failed')){draft.error='A photo could not be uploaded. Try it again or remove it before submitting.';render();return;}
      if(draft.request&&draft.requestSent){await sendFinal(item,draft);return;}
      draft.error='';notice='';
      try{for(const f of draft.files)await ensureCommand(id,draft,f);}catch{draft.error='A photo could not be read on this device. Remove it and add it again.';render();return;}
      /* Frozen now (and saved before anything is sent): the note, the photos in list order and a new operation. */
      draft.request={mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)};
      draft.requestSent=false;draft.submitRequested=true;await persistNow(id);
      const ready=draft.files.filter(f=>f.ready).length;
      announce(ready===draft.files.length?'Sending your fix for review':`Your fix will be sent when the photos finish uploading: ${ready} of ${draft.files.length} uploaded`);
      render();pump();await maybeSend(id);return;
    }
    if(navigator.onLine===false){offline=true;draft.error=interrupted().message;render();return;}
    busy=true;draft.error='';notice='';draft.stage=`Uploading photos… ${draft.files.filter(f=>f.ready).length} of ${draft.files.length} sent`;render();
    let sent=false;
    try{await uploadAll(item,draft);
      if(!draft.request){draft.request={mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)};persist(id);}
      draft.stage='Sending your fix for review…';render();
      const result=await request(`${root}/snags/${id}/workflow/submit`,draft.request);
      if(result.status!=='awaiting_review')throw new Error('Check the latest snag status before taking further action.');
      /* The server answers after its commit, so this is the durable acknowledgement: show it now and let the
         list refresh follow in the background. The card takes the status and revisions from that answer only;
         the submission history fills in from the refresh. */
      Object.assign(item,{status:result.status,revision:result.revision,workflowRevision:result.workflowRevision});
      forget(id);sent=true;notice=`Your fix for ${item.reference} was sent for review. The manager will check your evidence.`;
    }catch(error){draft.error=error.message;if(error.status===409){await load();}else if(error.identifier==='pin_required'){gate(error);}}
    finally{busy=false;if(drafts.get(id))drafts.get(id).stage='';pumpPhotos();
      if(sent){render();document.getElementById('snag-'+id)?.focus({preventScroll:true});load();}
      else await load();}
  });
  content.addEventListener('click',async event=>{
    const button=event.target.closest('button');if(!button||button.disabled)return;
    if(button.hasAttribute('data-refresh')){await load();return;}
    if(button.dataset.choose){document.getElementById('files-'+button.dataset.choose)?.click();return;}
    if(button.dataset.page){page=Number(button.dataset.page);await load();content.focus();scrollTo({top:0,behavior:'instant'});return;}
    if(button.dataset.photo){const item=current.items.find(i=>i.id===button.dataset.snag),photo=item.photos.find(p=>p.id===button.dataset.photo);const dialog=document.getElementById('photo-viewer'),img=dialog.querySelector('img');img.src=photoBlobs.get(photoURL(item,photo))||photoURL(item,photo);img.alt=`${photo.label} evidence for ${item.reference} · ${item.title}`;dialog.showModal();return;}
    if(button.dataset.discard){if(busy||!confirm('Discard the unsent notes and photos saved for this snag?'))return;if(early()){await discardDraft(button.dataset.discard);}else{forget(button.dataset.discard);render();}return;}
    if(button.dataset.cancelSend){const draft=drafts.get(button.dataset.cancelSend);if(draft&&!draft.requestSent){draft.submitRequested=false;draft.request=null;persist(button.dataset.cancelSend);render();announce('Not sent. Your notes and photos are kept.');}return;}
    const id=button.dataset.open||button.dataset.cancel||button.dataset.rebase||button.dataset.start||button.dataset.snag;
    if(!id||busy)return;const item=current.items.find(i=>i.id===id),draft=draftFor(item);
    if(button.dataset.open){draft.open=true;render();document.getElementById('note-'+id)?.focus();}
    if(button.dataset.cancel){draft.open=false;render();document.getElementById('open-'+id)?.focus({preventScroll:true});}
    if(button.dataset.remove!==undefined){const f=draft.files.find(x=>x.key===button.dataset.remove);if(!f)return;if(early()){await removeFile(item,draft,f);}else{release(draft.files.splice(draft.files.indexOf(f),1));persist(id);render();}}
    if(button.dataset.retryFile!==undefined){const f=draft.files.find(x=>x.key===button.dataset.retryFile);if(f&&f.status==='failed'){f.status='queued';f.attempts=0;f.error='';f.networkFailed=false;render();pump();}}
    if(button.dataset.rebase&&actionable(item)){draft.revision=item.revision;draft.workflowRevision=item.workflowRevision;draft.request=null;draft.requestSent=false;draft.submitRequested=false;draft.error='';
      for(const f of draft.files)if(!f.ready){if(early()&&f.command){draft.tombstones?.add(low(f.command.id));queueRetire(id,f.command.id);}if(f.xhr){try{f.xhr.abort();}catch{}}f.command=null;f.status='queued';f.attempts=0;}
      persist(id);render();if(early()){pump();drainRetirements(id);}}
    if(button.dataset.start){busy=true;draft.error='';render();try{if(!draft.startRequest)draft.startRequest={mutation:meta(),expectedRevision:item.revision,expectedWorkflowRevision:item.workflowRevision};const result=await request(`${root}/snags/${id}/workflow/start`,draft.startRequest);draft.startRequest=null;draft.revision=result.revision;draft.workflowRevision=result.workflowRevision;}catch(error){draft.error=error.message;}finally{busy=false;await load();}}
  });
  const dialog=document.getElementById('photo-viewer');dialog.querySelector('button').addEventListener('click',()=>dialog.close());dialog.addEventListener('close',()=>dialog.querySelector('img').removeAttribute('src'));
  addEventListener('offline',()=>{offline=true;render();});
  addEventListener('online',()=>{offline=false;notice=[...drafts.values()].some(d=>d.note||d.files.length)?'You are back online. Check your photos below and send your fix.':'';
    for(const d of drafts.values())for(const f of d.files){f.waitingForSignal=false;if(early()&&f.status==='failed'&&f.networkFailed){f.status='queued';f.attempts=0;f.error='';f.networkFailed=false;}}
    render();pump();if(!busy)load();});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'){for(const id of drafts.keys())persist(id);}else if(!busy&&current)load();});
  addEventListener('pagehide',()=>{for(const id of drafts.keys())persist(id);});
  addEventListener('beforeunload',event=>{if(busy||inFlight>0||[...drafts.values()].some(d=>d.submitRequested)||(!storageReady&&[...drafts.values()].some(d=>d.note||d.files.length))){event.preventDefault();event.returnValue='';}});
  (async()=>{try{storageReady=await device.ready();if(storageReady)deviceId=(await device.deviceId())||deviceId;}catch{storageReady=false;}load();})();
})();
