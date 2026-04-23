# Stable code-signing for CI releases

By default, GitHub Actions releases use **ad-hoc signing** (no identity). Every release then gets a different code-signature hash, and macOS TCC permissions (Microphone, Accessibility, Input Monitoring) don't carry from one release to the next. Users end up in the "Settings says granted but the app thinks it isn't" loop every time they upgrade.

The fix: sign every CI release with the same self-signed certificate. One-time setup, ~5 minutes.

---

## 1 · Export the cert from Keychain Access

You already have a **"HandsFree Dev"** cert from running `./scripts/setup-signing.sh` locally.

1. Open **Keychain Access** (⌘Space → type *"Keychain Access"*).
2. Sidebar → **login** keychain → category **My Certificates**.
3. Find the row labelled **HandsFree Dev** — it should have a disclosure triangle with the private key listed underneath.
4. Right-click **HandsFree Dev** → **Export "HandsFree Dev"…**
5. File format: **Personal Information Exchange (.p12)**. Save to `~/Desktop/HandsFree-Dev.p12`.
6. You'll be asked for an **export password** — pick a strong one, remember it.
7. macOS may then ask for your **Mac login password** — enter it.

## 2 · Base64-encode the cert

```bash
base64 -i ~/Desktop/HandsFree-Dev.p12 | pbcopy
```

The encoded blob is now on your clipboard.

## 3 · Add the two GitHub secrets

Open https://github.com/Harikrishnareddyl/hands_free/settings/secrets/actions and click **New repository secret** twice:

| Name | Value |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Paste from clipboard |
| `SIGNING_CERT_PASSWORD` | The export password you picked in step 1 |

## 4 · Cut a release

```bash
git tag v0.1.2 && git push origin v0.1.2
```

Look at the Actions tab — the **Import signing certificate** step should log:

```
Imported identity: HandsFree Dev
```

And the resulting DMG's `codesign -dv` will show `Authority=HandsFree Dev` instead of `Signature=adhoc`.

## 5 · Delete the .p12 from your Desktop

You don't need it anymore — the original cert + key still live in your Keychain. The .p12 on disk is sensitive (contains your private key), so delete it:

```bash
rm -P ~/Desktop/HandsFree-Dev.p12
```

---

## What this changes

- Every CI release is signed with the same `HandsFree Dev` identity.
- Designated requirement: `identifier "com.lakkireddylabs.HandsFree" and certificate leaf = H"<fingerprint>"`.
- The fingerprint is stable for the 10-year lifetime of the cert.
- TCC grants (Mic, Accessibility, Input Monitoring) persist across every release signed with the same cert.

## Caveats

- **Still not notarized.** Gatekeeper will continue to show the "unidentified developer" warning on first download. `install.sh` handles it with `xattr -dr com.apple.quarantine`. For true notarization, you'd need a paid Apple Developer Program membership ($99/yr) and a "Developer ID Application" cert from Apple.
- **First upgrade after this change still breaks TCC once.** Users upgrading from an ad-hoc-signed release (v0.1.0, v0.1.1) to the first stable-signed release will hit the TCC ghost issue one more time. From that release onward, grants persist.
- **Don't commit the .p12 to git.** It contains your private key. The `.gitignore` already excludes loose p12 files; the one on your Desktop is only transient.
- **If the cert expires or gets revoked**, regenerate with `./scripts/setup-signing.sh` and repeat this document.

## Verifying the setup

After the first stable-signed release:

```bash
# Download the DMG
curl -fL -o HandsFree-x.y.z.dmg \
  "https://github.com/Harikrishnareddyl/hands_free/releases/download/vX.Y.Z/HandsFree-X.Y.Z.dmg"

# Mount it
hdiutil attach HandsFree-x.y.z.dmg -nobrowse

# Inspect the signature
codesign -dv /Volumes/HandsFree/HandsFree.app 2>&1 | grep -E "(Authority|TeamIdentifier)"
```

You should see `Authority=HandsFree Dev` (instead of the ad-hoc line).
