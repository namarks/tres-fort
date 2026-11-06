# Brand

`app-icon.svg` is the source of the app icon: a cream fort with an orange gate
on dark navy. The fort is the "Fort" in Très Fort and belongs to no single
sport.

| Color | Hex | Use |
|---|---|---|
| Navy | `#15273e` | Icon background |
| Cream | `#f4f0e6` | Fort |
| Vermilion | `#ed4929` | Gate |

The PNG copies are 1024 × 1024, RGB with no alpha channel (App Store Connect
rejects an app icon with transparency). Re-export all four together after
changing the SVG:

- `ios/TresFort/Assets.xcassets/AppIcon.appiconset/icon-1024.png`
- `website/public/assets/app-icon.png`
- `web/public/assets/app-icon.png`
- `plugins/tres-fort/assets/icon.png`
