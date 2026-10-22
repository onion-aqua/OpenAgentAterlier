# Live2D runtime integration

This project keeps character dialogue and performance planning independent of
the renderer. The shared planning vocabulary remains semantic (`wave`,
`happy`, `think`, and similar); each renderer resolves those choices against
the resources loaded for the active character. A Live2D model must never reuse
another character's model directory or resource cache key.

## Model bundle

The runtime expects a Cubism 3-or-later runtime model bundle containing its `.model3.json`,
`.moc3`, texture files, and every motion, expression, physics, pose, and other
file referenced by `FileReferences`. Zip the complete directory and import it
from the virtual phone's **Outfits → Import model / scene ZIP → Live2D** entry.
The empty-character screen also has a direct import button. Importing adds a
card; select **Equip** to activate it. The model belongs to the character
selected during import. No model files are embedded in the app or repository.
The selected model ID follows the character/save; model files remain private
to the local device and are not part of portable settings/chat exports.

The importer permits one `.model3.json` per ZIP, preserves its relative
directories, and checks every referenced file before committing the import.
Use `performance.manifest.json` (or `manifest.json`) next to the `.model3.json`
for semantic bindings. Compressed ZIPs are limited to 128 MB, expanded contents
to 256 MB and a single file to 128 MB. No password-protected archives, symlinks,
absolute paths, duplicate paths or parent traversal are accepted. See
`lib/src/local_live2d_store.dart` for the complete validation rules.

The `.model3.json` is the source of truth for available motion groups,
expressions, and parameter groups. A companion manifest may define how this
application's semantic action and expression names map to those model assets.
Mappings are validated against the model descriptor before they are offered to
the planner:

```json
{
  "modelId": "character-id",
  "idle": { "group": "Idle", "index": 0 },
  "actions": {
    "wave": {
      "group": "TapBody",
      "index": 0,
      "description": "A short greeting wave",
      "aliases": ["greet", "hello"]
    }
  },
  "expressions": {
    "happy": { "name": "Smile", "aliases": ["joy"] },
    "neutral": { "index": 0 }
  },
  "parameters": {
    "mouthOpen": "ParamMouthOpenY",
    "angleX": "ParamAngleX",
    "angleY": "ParamAngleY",
    "bodyAngleX": "ParamBodyAngleX"
  }
}
```

Only actions backed by an actual motion group/index are advertised as
playable. A missing exact action resolves to no new action; it does not select
an unrelated motion. Missing expressions fall back to the model's explicitly
named neutral expression when one exists. Models with no explicit posture
mapping do not claim Spine-style seated or standing capabilities.

`idle` is optional. When present, its exact group/index must exist in the
model, including models that use an empty string as a real motion group. The
runtime returns to this motion after a foreground action ends; configuring it
does not interrupt or restart the current action. Invalid idle declarations
are rejected during import instead of becoming a silent runtime no-op.

## Speaking and interaction

The Cubism runtime renders the model's authored physics. The renderer adapter
supports semantic actions, native motion IDs, expressions, pause/resume and
mouth opening. TTS uses the app's existing audio amplitude envelope when
available; if decoding cannot provide an envelope, mouth movement uses a
procedural fallback. This is amplitude lip sync, not phoneme/viseme recognition.
The mouth parameter comes from `parameters.mouthOpen` or the model's `LipSync`
parameter group. Motion `Sound` files can be retained in the imported bundle;
the app does not start an additional audio player for them. TTS remains owned
by the app audio pipeline.

Only native motions present in this model are sent to the planner, with a
bounded candidate window. `grp_live2d_*` IDs never resolve through Spine's
motion catalog. Native group/file names alone cannot reveal an unlabelled
hand pose or movement angle: add accurate descriptions to the manifest for
precise semantics. Missing exact actions resolve to none, not an unrelated
gesture. Models do not inherit another character's expressions or posture.

## Current model availability

Spine and Live2D are selected from the active character's imported cards.
No dynamic model is preinstalled. Missing resources show an import prompt;
chat remains available. Old imported Spine packages are preserved as Ryza's
packages. A copied save whose model is absent on this device cannot load a
different character's model as a fallback.

Unit/widget tests cover descriptor parsing, imports, isolation, model switching,
and commands using a fake native transport. Real rendering and model-specific
semantic accuracy require acceptance with the target licensed model on Android
and Windows; fake transport tests do not establish visual acceptance.

For the fixed local `live2d_flutter` package and native prerequisites see
`docs/live2d_runtime_patch.md`. Build/run continues through the project wrappers.

## Third-party license

The `live2d_flutter` package's Dart/plugin source is BSD 3-Clause, but its
bundled Live2D Cubism Native SDK and Cubism Core have separate Live2D license
terms. Review the applicable terms for the app's distribution and commercial
use before shipping a build that contains the native runtime. The plugin also
requires retaining its BSD notice in redistributions. See:

- [Live2D Free Material License](https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html)
- [Live2D Proprietary Software License](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html)
- [Live2D Distribution License](https://www.live2d.com/eula/live2d-distribution-license_en.html)
- [live2d_flutter package](https://pub.dev/packages/live2d_flutter)
