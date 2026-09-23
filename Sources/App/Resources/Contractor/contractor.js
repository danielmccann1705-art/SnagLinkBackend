/* Canonical Contractor link. Keeps drafts and immutable retry requests in memory;
   no customer notes, photo bytes or bearer capability are placed in web storage. */
(() => {
  'use strict';
  const token = location.pathname.split('/')[2];
  const root = `/api/v2/contractor/${encodeURIComponent(token)}`;
  const content = document.querySelector('#content');
  const drafts = new Map();
  const histories = new Map();
  const labels = {open:'Open',in_progress:'In progress',awaiting_review:'Awaiting review',changes_requested:'Changes requested',closed:'Closed · accepted'};
  let current, page = 1, busy = false, pageError = '';
  const uuid = () => crypto.randomUUID();
  const meta = () => ({operationId:uuid(),deviceId:deviceId});
  const deviceId = uuid();
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const actionable = item => current?.mode === 'completion' && ['open','in_progress','changes_requested'].includes(item.status);
  const date = value => value ? new Intl.DateTimeFormat('en-GB',{day:'numeric',month:'short',year:'numeric'}).format(new Date(value.length === 10 ? value+'T12:00:00Z' : value)) : '';
  async function request(path, body, method = 'POST', mime = 'application/json') {
    const response = await fetch(path, {method,credentials:'same-origin',cache:'no-store',headers:method === 'GET' ? {} : {'Content-Type':mime,'X-Snaglist-Contractor':'1'},body:body === undefined ? undefined : mime === 'application/json' ? JSON.stringify(body) : body});
    let result; try { result = await response.json(); } catch { throw new Error('The connection was interrupted. Your notes are retained. Try again.'); }
    if (!response.ok) throw Object.assign(new Error(result.reason || 'This action could not be completed.'),{status:response.status,identifier:result.identifier});
    return result;
  }
  const photoURL = (item,photo) => `${root}/snags/${item.id}/media/${photo.id}/content`;
  function renderPhotos(item) {
    if (!item.photos.length) return '<p class="empty-photo">No shared photos for this snag.</p>';
    return `<div class="photo-grid">${item.photos.map(p => `<button class="photo-button" data-photo="${p.id}" data-snag="${item.id}" aria-label="Enlarge ${escape(p.label.toLowerCase())} photo for ${escape(item.reference)}"><img src="${photoURL(item,p)}" alt="${escape(p.label)} evidence for ${escape(item.title)}" loading="lazy"><span>${escape(p.label)} photo · Enlarge</span></button>`).join('')}</div>`;
  }
  function submission(item,draft) {
    const stale = draft.revision !== item.revision || draft.workflowRevision !== item.workflowRevision;
    const locked = busy || Boolean(draft.request) || stale;
    return `<form class="submission" data-submit="${item.id}">
      <h3>Submit your fix for review</h3><p class="help">Add after photos showing the completed work. The manager will review your evidence before this snag is closed.</p>
      ${stale ? `<div class="notice">The snag has changed since you started. Check the current details and feedback above. Your notes and photos are retained.<div class="actions"><button type="button" class="secondary" data-rebase="${item.id}" ${busy?'disabled':''}>I have reviewed the latest details</button></div></div>`:''}
      <label for="note-${item.id}">What did you fix?</label><textarea id="note-${item.id}" data-note="${item.id}" maxlength="10000" ${locked?'readonly':''} placeholder="Describe the repair and any checks you carried out">${escape(draft.note)}</textarea>
      <p class="field-label">After photos <span class="help">(required)</span></p><p class="help">JPEG or PNG, up to 10 MB each. Up to 20 photos.</p>
      <button type="button" class="secondary" data-choose="${item.id}" aria-describedby="terms-${item.id}" ${locked?'disabled':''}>Add after photos</button>
      <input id="files-${item.id}" data-files="${item.id}" type="file" accept="image/jpeg,image/png" multiple hidden tabindex="-1" aria-hidden="true" ${locked?'disabled':''}>
      <div>${draft.files.map((file,i) => `<div class="upload-file"><span>${escape(file.file.name)}<br><span class="help">${file.ready?'Processed and ready':file.progress||'Ready to upload'}</span></span><button class="secondary" type="button" data-remove="${i}" data-snag="${item.id}" ${locked?'disabled':''}>Remove</button></div>`).join('')}</div>
      <p class="help terms-notice" id="terms-${item.id}">Your photos and notes will be shared with the project team and may appear in project reports. Upload only information you have permission to share. By submitting, you agree to the <a href="https://usesnaglist.com/terms#contractor-links" target="_blank" rel="noopener noreferrer" aria-label="Contractor link terms (opens in a new tab)">Contractor link terms</a>. Read our <a href="https://usesnaglist.com/privacy" target="_blank" rel="noopener noreferrer" aria-label="privacy notice (opens in a new tab)">privacy notice</a> to understand how your information is used.</p>
      ${draft.error?`<p class="error" role="alert">${escape(draft.error)}</p>`:''}
      <div class="actions"><button type="submit" class="primary" aria-describedby="terms-${item.id}" ${busy||stale?'disabled':''}>${busy?'Sending your fix…':draft.request?'Retry submission':'Submit for review'}</button><button type="button" class="secondary" data-cancel="${item.id}" ${busy?'disabled':''}>Back to snag</button></div>
      <p class="help">Keep this page open while your photos upload. We’ll confirm when your fix has been sent for review.</p></form>`;
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
  function render() {
    if (!current) return;
    const y = scrollY, active = document.activeElement, focused = active?.id, start = active?.selectionStart, end = active?.selectionEnd;
    const counts = {work:0,review:0,closed:0};
    current.items.forEach(i=>counts[i.status==='closed'?'closed':i.status==='awaiting_review'?'review':'work']++);
    content.innerHTML = `<div class="intro"><p class="eyebrow">${escape(current.contractorName || 'Shared project snags')}</p><h1>${escape(current.projectName)}</h1>${current.projectAddress?`<p class="project-meta">${escape(current.projectAddress)}</p>`:''}<p class="help">Link expires ${escape(date(current.expiresAt))} · No account needed</p></div>
      ${current.mode!=='completion'?`<p class="notice"><strong>${current.mode==='preview'?'Preview · read only':'Read-only Contractor link'}</strong><br>You can view the shared snags. This link cannot submit evidence or change their status.</p>`:''}
      <div class="status-guide" aria-label="Statuses on this page"><span><strong>${counts.work}</strong>Need work</span><span><strong>${counts.review}</strong>Awaiting review</span><span><strong>${counts.closed}</strong>Accepted &amp; closed</span></div>
      <div class="list-tools"><p>${current.total} shared snag${current.total===1?'':'s'}${current.total>25?' · Counts above are for this page':''}</p><button class="secondary" data-refresh ${busy?'disabled':''}>Check for updates</button></div>
      ${pageError?`<p class="error" role="alert">${escape(pageError)}</p>`:''}
      ${current.items.length?current.items.map(card).join(''):'<div class="empty"><h2>No snags to show</h2><p>This link has no current snag assignments. Ask the project manager if you expected work here.</p></div>'}
      ${page>1||current.hasMore?`<nav class="pagination" aria-label="Snag pages"><button class="secondary" data-page="${page-1}" ${page===1||busy?'disabled':''}>Previous</button><span>Page ${page}</span><button class="secondary" data-page="${page+1}" ${!current.hasMore||busy?'disabled':''}>Next</button></nav>`:''}`;
    content.querySelectorAll('img').forEach(img => img.addEventListener('error',()=>{ const button = img.closest('button'); if(button){button.disabled=true;button.querySelector('span').textContent='Photo unavailable · check for updates';} }));
    if (focused) { const el = document.getElementById(focused); if(el){el.focus({preventScroll:true}); if(typeof start === 'number' && el.setSelectionRange) el.setSelectionRange(start,end); } }
    scrollTo({top:y,behavior:'instant'});
  }
  function gate(error) {
    const needsPIN = error.identifier === 'pin_required';
    content.innerHTML = `<section class="gate"><p class="eyebrow">Contractor link</p><h1>${needsPIN?'Enter your PIN':'This link is unavailable'}</h1><p>${escape(error.message)}</p>${needsPIN?`<form class="pin-form"><label for="link-pin">PIN from your project manager</label><input id="link-pin" name="pin" type="password" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{4,8}" minlength="4" maxlength="8" required><p class="pin-error" role="alert"></p><button class="primary">Open snag list</button></form>`:'<p class="help">Ask the project manager to share a new Contractor link.</p><button class="secondary" data-refresh>Try again</button>'}</section>`;
    const form = content.querySelector('.pin-form');
    form?.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{await request(root+'/verify-pin',{pin:form.elements.pin.value});form.elements.pin.value='';await load();}catch(e){form.querySelector('.pin-error').textContent=e.message;button.disabled=false;}});
  }
  async function load() {
    try {
      const result = await request(root+'?page='+page,undefined,'GET');
      current = result; pageError = '';
      for(const item of current.items){const draft=drafts.get(item.id); if(draft&&item.submissions.some(s=>s.id===draft.intent)) drafts.delete(item.id);}
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
  async function processFile(item,draft,file) {
    if(file.ready)return;
    const bytes=await file.file.arrayBuffer();
    if(!file.command){const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))).map(b=>b.toString(16).padStart(2,'0')).join('');file.command={mutation:meta(),id:uuid(),expectedRevision:draft.revision,purpose:'completion',intentId:draft.intent,sha256:sha,byteCount:bytes.byteLength,mimeType:file.file.type};}
    file.progress='Uploading and checking…';render();
    await request(`${root}/snags/${item.id}/media`,file.command);
    const result=await request(`${root}/snags/${item.id}/media/${file.command.id}/content`,bytes,'PUT',file.file.type);
    if(result.state!=='ready')throw new Error('This photo is not ready. Try again before submitting.');
    file.ready=true;render();
  }
  content.addEventListener('toggle',event=>{if(event.target.dataset.history)histories.set(event.target.dataset.history,event.target.open);},true);
  content.addEventListener('input',event=>{const id=event.target.dataset.note;if(id)drafts.get(id).note=event.target.value;});
  content.addEventListener('change',event=>{
    const id=event.target.dataset.files;if(!id)return;
    const draft=drafts.get(id);draft.error='';
    for(const file of event.target.files){if(!['image/jpeg','image/png'].includes(file.type)||file.size<=0||file.size>10485760){draft.error='Choose JPEG or PNG photos up to 10 MB each.';continue;}if(draft.files.length>=20){draft.error='Choose up to 20 photos.';break;}draft.files.push({file});}
    render();
  });
  content.addEventListener('submit',async event=>{
    const id=event.target.dataset.submit;if(!id)return;event.preventDefault();if(busy)return;
    const item=current.items.find(i=>i.id===id),draft=drafts.get(id);
    if(!actionable(item)||draft.revision!==item.revision||draft.workflowRevision!==item.workflowRevision)return;
    if(!draft.files.length){draft.error='Add at least one after photo showing the completed work.';render();return;}
    busy=true;draft.error='';render();
    try{for(const file of draft.files)await processFile(item,draft,file);
      if(!draft.request)draft.request={mutation:meta(),expectedRevision:draft.revision,expectedWorkflowRevision:draft.workflowRevision,attemptId:draft.intent,notes:draft.note,evidenceIds:draft.files.map(f=>f.command.id)};
      const result=await request(`${root}/snags/${id}/workflow/submit`,draft.request);
      if(result.status!=='awaiting_review')throw new Error('Check the latest snag status before taking further action.');
      drafts.delete(id);
    }catch(error){draft.error=error.message;if(error.status===409){await load();}else if(error.identifier==='pin_required'){gate(error);}}
    finally{busy=false;await load();if(!drafts.has(id))document.getElementById('snag-'+id)?.focus({preventScroll:true});}
  });
  content.addEventListener('click',async event=>{
    const button=event.target.closest('button');if(!button||button.disabled)return;
    if(button.hasAttribute('data-refresh')){await load();return;}
    if(button.dataset.choose){document.getElementById('files-'+button.dataset.choose)?.click();return;}
    if(button.dataset.page){page=Number(button.dataset.page);await load();content.focus();scrollTo({top:0,behavior:'instant'});return;}
    if(button.dataset.photo){const item=current.items.find(i=>i.id===button.dataset.snag),photo=item.photos.find(p=>p.id===button.dataset.photo);const dialog=document.getElementById('photo-viewer'),img=dialog.querySelector('img');img.src=photoURL(item,photo);img.alt=`${photo.label} evidence for ${item.reference} · ${item.title}`;dialog.showModal();return;}
    const id=button.dataset.open||button.dataset.cancel||button.dataset.rebase||button.dataset.start||button.dataset.snag;
    if(!id||busy)return;const item=current.items.find(i=>i.id===id),draft=draftFor(item);
    if(button.dataset.open){draft.open=true;render();document.getElementById('note-'+id)?.focus();}
    if(button.dataset.cancel){draft.open=false;render();document.getElementById('open-'+id)?.focus({preventScroll:true});}
    if(button.dataset.remove!==undefined){draft.files.splice(Number(button.dataset.remove),1);render();}
    if(button.dataset.rebase&&actionable(item)){draft.revision=item.revision;draft.workflowRevision=item.workflowRevision;draft.request=null;draft.error='';for(const f of draft.files)if(!f.ready)f.command=null;render();}
    if(button.dataset.start){busy=true;draft.error='';render();try{if(!draft.startRequest)draft.startRequest={mutation:meta(),expectedRevision:item.revision,expectedWorkflowRevision:item.workflowRevision};const result=await request(`${root}/snags/${id}/workflow/start`,draft.startRequest);draft.startRequest=null;draft.revision=result.revision;draft.workflowRevision=result.workflowRevision;}catch(error){draft.error=error.message;}finally{busy=false;await load();}}
  });
  const dialog=document.getElementById('photo-viewer');dialog.querySelector('button').addEventListener('click',()=>dialog.close());dialog.addEventListener('close',()=>dialog.querySelector('img').removeAttribute('src'));
  addEventListener('beforeunload',event=>{if([...drafts.values()].some(d=>d.note||d.files.length)){event.preventDefault();event.returnValue='';}});
  load();
})();
