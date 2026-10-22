// Local diagnostic; pass a Spine 4.2 JS bundle and a directory of owned rigs.
// Textures are neither loaded nor copied. This does not validate rendering.
const fs = require('node:fs');
const path = require('node:path');
const spine = eval(fs.readFileSync(process.argv[2], 'utf8') + '\n;spine');
const atlas = {findRegion(name) { return {name, width: 2, height: 2,
  u: 0, v: 0, u2: 1, v2: 1, x: 0, y: 0, rotate: false, degrees: 0}; }};
const reader = new spine.SkeletonBinary(new spine.AtlasAttachmentLoader(atlas));
for (const directory of fs.readdirSync(process.argv[3], {withFileTypes: true})) {
  if (!directory.isDirectory()) continue;
  const file = path.join(process.argv[3], directory.name, directory.name + '.skel');
  if (!fs.existsSync(file)) continue;
  const data = reader.readSkeletonData(fs.readFileSync(file));
  const wind = data.animations.filter(a => a.name.startsWith('effect_wind'));
  if (process.argv.includes('--verify')) {
    const skeleton = new spine.Skeleton(data);
    const state = new spine.AnimationState(new spine.AnimationStateData(data));
    const entry = state.setAnimation(17, wind[0].name, true);
    entry.mixBlend = spine.MixBlend.replace;
    entry.alpha = 0.5;
    let maximum = 0;
    for (let frame = 0; frame < 600; frame++) {
      if (frame === 480) entry.alpha = 0;
      state.update(1 / 60);
      state.apply(skeleton);
      skeleton.update(1 / 60);
      skeleton.updateWorldTransform(spine.Physics.update);
      for (const constraint of skeleton.physicsConstraints) {
        const value = Math.abs(constraint.wind - constraint.data.wind);
        maximum = Math.max(maximum, value);
        if (!Number.isFinite(value) || value > 2.501) throw new Error(directory.name + ': accumulated wind');
        if (frame > 480 && value > 0.001) throw new Error(directory.name + ': residual wind');
      }
    }
    console.log(JSON.stringify({skin: directory.name, windBoundedAndReturnsToZero: true, maximum}));
    continue;
  }
  console.log(JSON.stringify({skin: directory.name, hash: data.hash,
    physicsCount: data.physicsConstraints.length,
    physics: process.argv.includes('--verbose') ? data.physicsConstraints.map(c => ({name: c.name, bone: c.bone.name,
      inertia: c.inertia, strength: c.strength, damping: c.damping, wind: c.wind})) : undefined,
    wind: wind.map(a => ({name: a.name, duration: a.duration,
      timelines: a.timelines.map(t => ({type: t.constructor.name,
        index: t.constraintIndex, bone: data.physicsConstraints[t.constraintIndex]?.bone.name,
        frames: process.argv.includes('--verbose') ? Array.from(t.frames || []) : undefined}))}))}));
}
