# Native visual consistency pass

The library, player, and task panel now share Stint's charcoal surfaces and off-white actions. Timeline ranges use muted blue; labels and outcomes retain semantic colors. Fields, menus, chips, typography, gutters, and corner radii use the shared treatments documented in [Native UI conventions](../../UI.md). Clip cards keep range metadata below the footage, and the project header no longer adds a separate blue container.

## Verification

Both isolated Debug variants built and passed their focused offscreen suites on November 23, 2026:

| Variant | Result | Output |
| --- | --- | --- |
| Direct | 20 tests passed; zero failures or skips | [direct-tests.log](direct-tests.log) |
| MAS | 20 tests passed; zero failures or skips | [mas-tests.log](mas-tests.log) |

Each run rendered 33 native states and checked pending notes saving when switching tabs, the notes round trip, and preservation of the player across resizing. [native-layout.txt](native-layout.txt) records the final MAS run's requested and actual dimensions. Build logs reported only the existing AppIntents metadata warning. These checks do not establish system click automation, signed sandbox behavior, or release distribution.

The screenshot runner also captured six real window states with ScreenCaptureKit: library, Details, Notes, Export, and Details/Export at 900 points. Each was visually inspected, including the real video and filmstrip, menu surfaces, toolbar chrome, and narrow layouts. Only the two complementary library/workspace views appear in the [README gallery](../../../README.md#screenshots); their provenance is recorded with the [published images](../../screenshots/README.md).

```sh
CLIPX_BUILD_ROOT="$PWD/build/ui-workspace" \
CLIPX_PACKAGES_DIR="$PWD/build/ui-workspace/Packages" \
  ./Scripts/verify.sh offscreen

CLIPX_BUILD_ROOT="$PWD/build/ui-workspace" \
CLIPX_PACKAGES_DIR="$PWD/build/ui-workspace/Packages" \
  ./Scripts/verify.sh offscreen-mas

python3 Scripts/capture-screenshots.py \
  --derived-data build/ui-workspace/Direct \
  --packages-dir build/ui-workspace/Packages \
  --media-dir build/readme-screenshots/media \
  --output build/ui-harmony-final --review
```

All work used disposable data and the verification build identity. The Mac stayed locked, security settings remained unchanged, and the installed app and real library were not opened. No release or update feed was published.
