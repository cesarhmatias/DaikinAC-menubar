# Third-party notices

## LGwebOS-menubar

The menu bar shell, the design primitives and the build and privacy scripts are ported from
LGwebOS-menubar and adapted for this app. No LG or webOS logic, assets or brand material is included.

| File in this project | Ported from LGwebOS-menubar | What was taken |
|---|---|---|
| `Sources/DaikinACMenubar/main.swift` | `Sources/LGwebOSMenubar/main.swift` | `RemotePanel`, `PanelArrow`, `PanelShell`, `AppDelegate` (status item, panel placement, click/Escape dismissal, resize on `preferredPanelHeight`) and the `--self-check` entry point |
| `Sources/DaikinACMenubar/DesignSystem.swift` | `Sources/LGwebOSMenubar/RemoteView.swift` | `PanelButton` and `PanelCard`, made internal |
| `Sources/DaikinACMenubar/Theme.swift` | `main.swift`, `RemoteView.swift` | Panel width, corner radius, background gradient, border, ink and surface values |
| `Sources/DaikinACMenubar/ACView.swift` | `Sources/LGwebOSMenubar/RemoteView.swift` | Layout of the header, tab bar, section titles, feedback card and footer |
| `scripts/build.sh` | `scripts/build.sh` | Anonymous-path release build, app bundle, Info.plist and ad-hoc signing |
| `scripts/privacy-check.py` | `scripts/privacy-check.py` | File discovery and the path, private-IP and MAC checks |

LGwebOS-menubar is distributed under the MIT License:

```text
MIT License

Copyright (c) 2026 LGwebOS-menubar contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## BigInt (dependency)

[`attaswift/BigInt`](https://github.com/attaswift/BigInt) provides the big-integer math for Cognito
`USER_SRP_AUTH`. It is the project's only dependency, pinned exactly to version 5.7.0 (revision
`e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe` in `Package.resolved`) and compiled into the app.
Version 5.7.0 is used rather than 6.x because 6.x requires the Swift 6 toolchain and changes nothing
this project uses.

BigInt is distributed under the MIT License:

```text
Copyright (c) 2016-2017 Károly Lőrentey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## References (not bundled, no code copied)

Daikin Brazil publishes open-source projects for the same devices, all under the MIT License
(Copyright (c) 2025 daikin-br). They were read to cross-check behavior:

- [`daikin-br/ha-custom-integration`](https://github.com/daikin-br/ha-custom-integration): mode and
  fan values, per-mode temperature ranges, DRY with automatic fan, mode 0 reported as AUTO, and
  mDNS discovery of `_iota._tcp`.
- [`daikin-br/pyiotdevice`](https://github.com/daikin-br/pyiotdevice): local frame layout, AES-CFB128
  and CRC-16. This project generates the CRC table from the polynomial and only compares a few of its
  entries with the published table in the self-check.
- [`daikin-br/ha-matterbridge-integration`](https://github.com/daikin-br/ha-matterbridge-integration):
  setup guide only.

The Cognito SRP exchange follows the public behavior of
[`aws/amazon-cognito-identity-js`](https://github.com/aws-amplify/amplify-js) and
[`pycognito`](https://github.com/NabuCasa/pycognito) (Apache License 2.0). The Swift code is this
project's own. pycognito 2024.5.1 was run offline only to compute the fixed reference values that
`--self-check` compares against; it is not bundled.

SF Symbols are provided by macOS and used under Apple's terms; none are bundled.
