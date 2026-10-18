# DaikinAC-menubar: guide for Claude

This is a native macOS menu bar app that controls a Daikin Smart AC (Brazil) and shows its energy use. It is being built now. Use this file both to build the app and, once it works, to set it up for a user. All project-authored text (code, comments, docs, UI) is English.

## Sources of truth

- **Protocol:** `research/DAIKIN_SMART_AC_PROTOCOL.md`. It was written by statically decompiling the Android app, and nothing in it has been checked against live traffic. Before you build UI on any response shape, confirm it with the user's own account and record what you saw.
- **External cross-check:** Daikin Brazil publishes two open-source projects for the same devices and backend: `https://github.com/daikin-br/ha-custom-integration` (Home Assistant) and `https://github.com/daikin-br/ha-matterbridge-integration`. Read them before you implement a channel, especially the local LAN channel. Where they disagree with the protocol doc, trust the repos and note the difference in `research/`. Check each repo's license before you copy any code, and credit what you use in `THIRD_PARTY_NOTICES.md`.
- **Visual design:** ported from the sibling checkout `../LGwebOS-menubar` (MIT). Copy only the shell and the design primitives listed below, credit them in `THIRD_PARTY_NOTICES.md`, and do not copy LG/webOS logic or assets.
- `research/` is ignored by git. It holds the protocol doc and the original `.xapk`. Never move either into a tracked path.

## Project layout and build rules

- Swift 5.9+, macOS 14+, SwiftPM only (no Xcode project), same as the LG project. Executable target `DaikinACMenubar`, bundle id `br.local.DaikinAC`, app `dist/DaikinAC-menubar.app`.
- Prefer zero dependencies. If one is unavoidable (SRP big-integer math, MQTT), ask the user first, pin an exact version, and add it to `THIRD_PARTY_NOTICES.md`.
- Expected files in `Sources/DaikinACMenubar/`:
  - `main.swift`: `RemotePanel`, `PanelArrow`, `PanelShell`, `AppDelegate`, ported from LG. The store must expose `@Published var preferredPanelHeight` because the shell subscribes to it. The status item symbol is `air.conditioner.horizontal`. Keep the `--self-check` entry point.
  - `DesignSystem.swift`: `PanelButton` and `PanelCard`, taken out of LG's `RemoteView.swift` and made internal (not private).
  - `Theme.swift`: every color and dimension in one place (panel width 360, corner radius 18, background gradient, border opacity) plus one accent per AC mode: COOL blue, HEAT orange, DRY teal, FAN neutral gray, AUTO green.
  - `ACState.swift`: the `port1` model and its enums. Mode values are AUTO=1, DRY=2, COOL=3, HEAT=4, FAN=6. Fan values are 3–7, AUTO=17, QUIET=18. Temperature is clamped to 10–32.
  - `CognitoAuth.swift`, `DaikinAPI.swift`, `ShadowClient.swift`, `LocalChannel.swift`, `Energy.swift`, `DeviceHealth.swift` (errors, diagnostics, firmware check, subscription), `Schedules.swift` (comfort profiles), `Keychain.swift`, `ACStore.swift`, `ACView.swift`, `FeatureChecks.swift`.
- Do not port `BrandTheme.swift`, `AppAssets/`, `app-catalog.json`, `registration.json`, `WebOS.swift`, `PointerChannel.swift`, `MediaBridge.swift` or `Discovery.swift`.

## Technical decisions already made

1. **Auth.** The user's own Daikin sign-in is what grants access to their AC (protocol §2.1). Neither of the two embedded secrets is needed: the native client secret and the Android DB password are not used, so don't build code paths around them.
   - Use the Amplify client `2tl54vtfepvo3nu23um3c6rjs9`, pool `us-east-1_s6T1EfUgP`. It is a public client with no secret, so requests carry no `SECRET_HASH`.
   - First try `InitiateAuth` with `USER_PASSWORD_AUTH`. If the pool rejects that flow, use `USER_SRP_AUTH` implemented by hand. That needs big-integer math, so ask the user before adding a dependency.
   - Refresh with `REFRESH_TOKEN_AUTH` before the tokens expire (about 1 h).
   - Get AWS credentials from the Identity Pool (`GetId` + `GetCredentialsForIdentity`) with the ID token. The ID token alone is enough for the REST API.
   - **Fallback, only with the user's approval:** that the no-secret client is accepted is still a static-analysis inference. If both flows are rejected on it, report the exact error and stop. The native client could then be used, with `SECRET_HASH = Base64(HMAC-SHA256(secret, username + clientId))`, but its secret is loaded at runtime from the Keychain or `.local/` and is never compiled in.
2. **Cloud state and control (MVP).** Skip MQTT. Use the AWS IoT shadow over HTTPS: `GET`/`POST https://a2zl28lcjjddi3-ats.iot.us-east-1.amazonaws.com/things/{thing_id}/shadow`, signed with SigV4 (service `iotdata`) using Identity Pool credentials from `GetId` + `GetCredentialsForIdentity`. Poll while the panel is open. Call the policy-attach endpoint (protocol §6.5) once per device first. MQTT push is a later upgrade.
3. **Commands** are `{"state":{"desired":{"port1":{…only changed keys…},"src":5}}}`. The command is applied once `desired` is cleared.
4. **Energy.** `kwh_value` is a cumulative meter reading. Keep the maximum reading per calendar day, then daily use = `max(0, today − previous day)`. Sync at most every 6 h, and send `last_record_date` so each sync is incremental.
5. **Local LAN channel (later phase).** Use CommonCrypto `CCCryptorCreateWithMode` with `kCCModeCFB` (CFB128, no padding). CryptoKit has no CFB mode. The key is `Base64(thing_secret_key + "\n")`, decoded with `.ignoreUnknownCharacters`. The plaintext gets the `"BZ"` suffix. The frame is `[IV16][ciphertext][CRC16 little-endian]`, sent base64-encoded. The CRC is CRC-16/GENIBUS: the self-check must give `0xD64E` for ASCII `"123456789"`. Responses come in two shapes (with and without a length byte), so handle both.
6. **Three success conventions.** `managething` returns `status: 0` (an integer). The energy endpoint returns `status: "success"` (a string). The comfort-profile and firmware endpoints signal failure with `statusCode` 500 or 1, with the reason in `message`. Parse each endpoint with its own convention.
7. **Device health comes from `GET_THING_INFO`, not a separate call.** Each response also carries `json_response.error_data[]` (`error_code`, `manufacturer_error_code`, …) and a per-device `cloud_subscription { status, expiry_date }`. Translate an error code with `GET_THING_ERROR_TRANSLATION`, sending `manufacturer_error_code: "DAIKIN:<code>"` and `country_lang_code: "pt-BR"`. Warn before the cloud subscription expires. Local LAN control does not depend on it.
8. **Firmware is read-only.** `GET_LATEST_FIRMWARE_DATA` may be shown. Progress is visible through the shadow's `fw_ver`; this endpoint is not polled.
9. **Comfort profiles (schedules).** Reads are `GET_COMFORT_PROFILES` (the list), `GET_COMFORT_PROFILE` (one profile) and `GET_COMFORT_PROFILE_EXEC_LOGS` (paged with `next_token`). The `settings` reuse the `port1` integers, and `days_of_week` uses `SUN`…`SAT`. `ADD`/`UPDATE`/`DELETE` change the user's real schedules. Build them only after reads are verified, and only behind an explicit confirmation in the UI.
10. **Do not build:** weather (dead code in v1.1.73, with no data source), push notifications (FCM/Pinpoint cannot reach a Mac; poll the shadow instead), and the `accesslog/active|inactive` analytics calls (the app sends no usage analytics). Account registration, verification and deletion are out of scope.

## Phases

Each phase is done only when `bash scripts/build.sh`, the `--self-check` binary flag and `python3 scripts/privacy-check.py` all pass. Stop after each phase and report to the user.

0. Repo scaffold and design shell with a placeholder view.
1. Sign-in and device list (`GET_THING_INFO`), keeping `error_data` and `cloud_subscription`.
2. Read the shadow state (including `sensors` and `fw_ver`) and send commands.
3. Energy tab: today, weekly and monthly totals.
4. Device health: translated error codes, diagnostics (§6.3), a read-only firmware check and the subscription-expiry warning.
5. Schedules: list comfort profiles and their execution logs (read-only), then add, edit and delete them with confirmation.
6. Local LAN channel, with the cloud as fallback, validated against the daikin-br repos.

## Setting the app up for a user (once phases 0–2 work)

1. Check the Mac: `sw_vers -productVersion` (14+) and `swift --version` (5.9+).
2. Build: `bash scripts/build.sh`.
3. Run the offline checks: `"dist/DaikinAC-menubar.app/Contents/MacOS/DaikinACMenubar" --self-check` and `python3 scripts/privacy-check.py`.
4. Open the app. The user signs in with their own Daikin Smart AC account in Settings. You never type or store their password yourself.
5. The user picks the device. Show a successful **read** of the state before sending any **write**.

## Rules

- **Secrets.** Not being allowed in a tracked file is different from not being usable (protocol §2.1). Values fall into three groups:
  - **Public identifiers, allowed in source:** the Amplify client ID, the User Pool ID, the Identity Pool ID, the region, the IoT endpoint and the `dmb.iotalabs.co.in` URLs.
  - **Embedded secrets, never in any tracked file (including this one):** the native app-client secret and the Android local DB password. They are not used. If the native fallback is ever approved, its secret lives only in the Keychain or `.local/`. Keep its value in `.local/deny.txt` so `privacy-check.py` blocks it.
  - **User data, loaded at runtime from the Keychain or `.local/`:** email, password, tokens, `thing_secret_key`, `thing_id`, the SoftAP password, IPs and MAC addresses. Never build-time constants and never tracked.
- **Own account only.** Never touch devices or accounts that are not the user's.
- **Read before write.** Ask the user before sending the first command to a real AC. Commands change a physical device in their home.
- **Never call** `/reset`, `/onboard`, `/done`, `/userdata`, `INITIATE_FIRMWARE_UPGRADE`, `ADD_THING`, `UPDATE_THING`, `DELETE_THING`, `DELETE_USER_ACCOUNT` or `accesslog/*`. The app must not expose them either. Comfort-profile `ADD`/`UPDATE`/`DELETE` run only on an explicit user action in the app, never from you during development.
- **Don't hammer the backend.** Respect the 6 h energy cadence. Don't retry sign-in in a loop, because Cognito rate-limits and may lock the account. If something fails, report the exact error and what you ruled out.
- **Git.** Never commit or push without the user's explicit approval. Never commit `dist/`, `research/`, `.local/`, `*.xapk` or `*.apk`. Never add a remote or push while any commit in history contains the `.xapk` or the protocol doc; check with `git log --all --stat`.
