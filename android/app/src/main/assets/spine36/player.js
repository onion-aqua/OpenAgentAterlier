/* Offline Spine 3.6 adapter. No character data or remote requests are bundled. */
"use strict";
(() => {
  const canvas = document.getElementById("stage");
  let gl, renderer, assets, skeleton, data, state, bounds, raf = 0, last = 0;
  let control = { paused: false }, actionNonce, actionName, mouthEntry;
  let loaded = false, failed = false;
  const clips = new Map();
  function event(type, value) {
    if (window.Spine36Host) window.Spine36Host.postMessage(JSON.stringify({ type, value }));
    else window.dispatchEvent(new CustomEvent("spine36", { detail: { type, value } }));
  }
  function fail(error) {
    if (failed) return;
    failed = true;
    cancelAnimationFrame(raf);
    event("error", String(error && error.message || error));
  }
  window.addEventListener("error", e => fail(e.error || e.message));
  window.addEventListener("unhandledrejection", e => fail(e.reason));
  canvas.addEventListener("webglcontextlost", e => {
    e.preventDefault();
    fail(new Error("Spine 3.6 graphics context lost; reload the model"));
  });

  function play(track, name, loop) {
    if (!name || !data.findAnimation(name)) return null;
    const current = state.getCurrent(track);
    return current && current.animation.name === name
      ? current : state.setAnimation(track, name, loop);
  }
  function sync(next) {
    const wasPaused = control.paused;
    control = next;
    if (!loaded || failed) return;
    if (!data.findAnimation(next.idle)) throw new Error("Mapped idle animation missing");
    play(0, next.idle, true);
    if (next.face) play(11, next.face, false);
    else if (state.getCurrent(11)) state.setEmptyAnimation(11, 0.2);
    if (next.action && (next.actionNonce !== actionNonce || next.action !== actionName)) {
      if (!data.findAnimation(next.action)) throw new Error("Mapped action missing");
      state.setAnimation(1, next.action, false);
      state.addEmptyAnimation(1, 0.25, 0);
    }
    actionNonce = next.actionNonce;
    actionName = next.action;
    if (next.speaking && next.mouth) {
      mouthEntry = play(13, next.mouth, false);
      if (mouthEntry) mouthEntry.timeScale = 0;
    } else if (mouthEntry) {
      mouthEntry = null;
      state.setEmptyAnimation(13, 0.15);
    }
    if (next.paused) { cancelAnimationFrame(raf); raf = 0; last = 0; }
    else if (!raf) { if (wasPaused) last = 0; raf = requestAnimationFrame(frame); }
  }
  window.spine36 = {
    update(next) { try { sync(next); } catch (error) { fail(error); } },
    dispose() {
      cancelAnimationFrame(raf);
      loaded = false;
      if (assets) assets.dispose();
      if (renderer) renderer.dispose();
    },
    // Read-only diagnostics used by the rendering smoke test.
    inspect() {
      return { loaded, failed, version: data && data.version,
        time: state && state.getCurrent(0) && state.getCurrent(0).trackTime,
        tracks: state && state.tracks.map(t => t && t.animation.name),
        mouthTime: mouthEntry && mouthEntry.trackTime };
    }
  };

  // In 3.6 an empty ending slot skips clipEnd(). End at the last drawable
  // attachment in that clip instead, or detach a clip containing no geometry.
  function endClips() {
    for (const slot of skeleton.slots) {
      const a = slot.getAttachment();
      if (a instanceof spine.ClippingAttachment && a.endSlot && !clips.has(a)) {
        clips.set(a, { slot, end: a.endSlot, detached: false });
      }
    }
    const order = skeleton.drawOrder;
    for (const [clip, c] of clips) {
      const a = c.slot.getAttachment();
      if (a !== clip && !(c.detached && a === null)) { c.detached = false; continue; }
      const from = order.indexOf(c.slot), to = order.findIndex(s => s.data === c.end);
      if (from < 0 || to < 0) continue;
      let end = null;
      for (let i = to; i > from; --i) {
        const attachment = order[i].getAttachment();
        if (attachment instanceof spine.RegionAttachment || attachment instanceof spine.MeshAttachment) {
          end = order[i].data; break;
        }
      }
      if (end) {
        clip.endSlot = end;
        if (c.detached) c.slot.setAttachment(clip);
        c.detached = false;
      } else { c.slot.setAttachment(null); c.detached = true; }
    }
  }
  function draw(dt) {
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.round(canvas.clientWidth * ratio));
    const h = Math.max(1, Math.round(canvas.clientHeight * ratio));
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    gl.viewport(0, 0, w, h);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    state.update(dt);
    if (mouthEntry) {
      const energy = Math.min(1, Math.max(0, Number(control.energy) || 0));
      mouthEntry.trackTime = mouthEntry.animation.duration * energy;
    }
    state.apply(skeleton); skeleton.updateWorldTransform(); endClips();
    const aspect = w / h;
    const height = Math.max(bounds.height, bounds.width / aspect) * 1.06;
    renderer.camera.position.x = bounds.x + bounds.width / 2;
    renderer.camera.position.y = bounds.y + bounds.height / 2;
    renderer.camera.setViewport(height * aspect, height);
    renderer.begin(); renderer.drawSkeleton(skeleton, true); renderer.end();
  }
  function frame(now) {
    raf = 0;
    if (!loaded || failed || control.paused) return;
    try {
      if (!last || now - last >= 1000 / 30) {
        draw(last ? Math.min((now - last) / 1000, 0.05) : 0);
        last = now;
      }
      raf = requestAnimationFrame(frame);
    } catch (error) { fail(error); }
  }
  async function start() {
    const context = new spine.webgl.ManagedWebGLRenderingContext(canvas,
      { alpha: true, premultipliedAlpha: true });
    gl = context.gl;
    if (!gl) throw new Error("WebGL unavailable for Spine 3.6");
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    renderer = new spine.webgl.SceneRenderer(canvas, context, true);
    assets = new spine.webgl.AssetManager(context);
    assets.loadTextureAtlas("model/model.atlas");
    assets.loadText("model/model.json");
    await new Promise((resolve, reject) => {
      const poll = () => {
        if (assets.hasErrors()) { reject(new Error(JSON.stringify(assets.getErrors()))); return; }
        if (assets.isLoadingComplete()) resolve(); else setTimeout(poll, 16);
      }; poll();
    });
    const atlas = assets.get("model/model.atlas");
    const json = JSON.parse(assets.get("model/model.json"));
    if (!/^3\.6(?:\.|$)/.test(json.skeleton && json.skeleton.spine)) {
      throw new Error("Only Spine 3.6 JSON belongs in this player");
    }
    data = new spine.SkeletonJson(new spine.AtlasAttachmentLoader(atlas)).readSkeletonData(json);
    skeleton = new spine.Skeleton(data);
    skeleton.setToSetupPose(); skeleton.updateWorldTransform();
    const offset = new spine.Vector2(), size = new spine.Vector2();
    skeleton.getBounds(offset, size, []);
    if (!(size.x > 0 && size.y > 0)) throw new Error("Skeleton has no visible geometry");
    bounds = { x: offset.x, y: offset.y, width: size.x, height: size.y };
    const stateData = new spine.AnimationStateData(data); stateData.defaultMix = 0.25;
    state = new spine.AnimationState(stateData);
    // Import validation renders the setup pose before accepting the package.
    draw(0); gl.finish();
    if (gl.getError() !== gl.NO_ERROR) throw new Error("Spine 3.6 WebGL drawing failed");
    loaded = true;
    event("ready", data.animations.map(a => a.name));
    if (control.idle) sync(control);
  }
  start().catch(fail);
})();
