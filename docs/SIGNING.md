# Signing & notarization for CI releases

With an **Apple Developer Program** membership ($99/yr), every CI release can be signed with a **Developer ID Application** certificate and **notarized by Apple**. End users then install HandsFree like any other Mac app — no quarantine, no System Settings dance, no "unidentified developer" warning, no manual `+` additions.

This document walks you through the one-time setup. After that, every `git tag vX.Y.Z && git push origin vX.Y.Z` produces a signed + notarized + stapled DMG automatically.

---

## 1 · Create a Developer ID Application certificate

**Via Xcode (easiest)**:

1. Open **Xcode → Settings** (`⌘,`) → **Accounts**.
2. Add your Apple ID if it's not listed.
3. Select the account → **Manage Certificates…**
4. Click the **+** at the bottom-left → **Developer ID Application**.
5. Xcode creates the cert and installs it in your login Keychain automatically.

**Alternatively** via the Apple Developer portal: [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) → `+` → **Developer ID Application** → upload a CSR generated from Keychain Access → download `.cer` → double-click to install.

## 2 · Find your Team ID

[developer.apple.com/account](https://developer.apple.com/account) → **Membership details** → copy the **Team ID** (10 characters, e.g. `ABCDE12345`).

## 3 · Generate an app-specific password for the notary service

1. [appleid.apple.com](https://appleid.apple.com/account/manage) → **Sign-In and Security** → **App-Specific Passwords** → **Generate Password…**
2. Label it `HandsFree CI`.
3. Copy the generated password (format: `abcd-efgh-ijkl-mnop`). You only get to see it once.

## 4 · Export the cert as a .p12

1. Open **Keychain Access** → **login** keychain → category **My Certificates**.
2. Find the row labelled **Developer ID Application: Your Name (TEAMID)**. It should have a disclosure triangle hiding the private key below it.
3. Right-click the row → **Export "Developer ID Application: …"**
4. Format: **Personal Information Exchange (.p12)**. Save to `~/Desktop/DevID.p12`.
5. Enter an **export password** when asked — pick a strong one, remember it.
6. macOS may prompt for your login password — enter it.

## 5 · Base64-encode the .p12

```bash
base64 -i ~/Desktop/DevID.p12 | pbcopy
```

The encoded blob is now on your clipboard.

## 6 · Add five GitHub repository secrets

Open https://github.com/Harikrishnareddyl/hands-free/settings/secrets/actions and create (or overwrite) these secrets:

| Name | Value |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Paste from clipboard (step 5). Overwrites the self-signed one if it was there. |
| `SIGNING_CERT_PASSWORD` | The .p12 export password you picked in step 4. |
| `APPLE_ID` | Your Apple ID email (used to submit notarization jobs). |
| `APPLE_TEAM_ID` | The 10-character Team ID from step 2. |
| `APPLE_APP_PASSWORD` | The app-specific password from step 3 (format `abcd-efgh-ijkl-mnop`). |

## 7 · Cut a release

```bash
git tag v0.1.6 && git push origin v0.1.6
```

Watch the GitHub Actions run. You should see logs like:

```
Imported identity: Developer ID Application: Your Name (TEAMID)
→ Signing app (identity: Developer ID Application: Your Name (TEAMID))
→ Creating DMG
→ Signing DMG
→ Submitting to Apple notary service
Processing complete
  status: Accepted
→ Stapling notarization ticket
```

Notarization typically takes 2–10 minutes. The workflow waits (`notarytool submit --wait`) before publishing, so if it succeeds, the DMG that lands on the Releases page is notarized and stapled.

## 8 · Clean up local artefacts

```bash
rm -P ~/Desktop/DevID.p12
```

The cert itself stays in your Keychain — you don't need the .p12 on disk anymore.

## What users see after notarization

- Download the DMG, double-click → mounts without any warning.
- Drag HandsFree into /Applications → double-click → launches normally. **No "unidentified developer" block.** No quarantine strip required. No `+` button in Settings. Permissions (Mic, Accessibility) prompt and register the way they should.
- `install.sh` still works and is still the recommended install command, but users can also use any of the standard download-and-open flows.

## Troubleshooting

**Notarization failed with "The signature does not include a secure timestamp"**
→ `build-dmg.sh` already signs with `--timestamp`. If codesign can't reach Apple's timestamp server (`timestamp.apple.com`), the build fails loudly. Check the runner has outbound HTTPS.

**Notarization failed with "Hardened runtime is not enabled"**
→ The `ENABLE_HARDENED_RUNTIME` build setting is already `YES` in `project.yml`. Shouldn't hit this.

**Notarization failed with an entitlements error**
→ The app is unsandboxed and only requests `com.apple.security.device.audio-input`. If we ever add private entitlements, update `HandsFree/HandsFree.entitlements` accordingly.

**Notarization failed with "Invalid credentials"**
→ The app-specific password from step 3 has expired or is wrong. Regenerate one and update the `APPLE_APP_PASSWORD` secret.

## Caveats

- The Developer ID cert expires after **5 years**. Regenerate from step 1 before then.
- Keep the `.p12` file off Git and off shared machines — it contains your private key.
- Notarization requires outbound internet from the runner (macos-15 on GitHub Actions has this by default).
