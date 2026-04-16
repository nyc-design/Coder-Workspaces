# Publishing to OpenVSX

This extension publishes under the `nyc-design` namespace because the `publisher` field in `package.json` is set to `nyc-design`.

If you want a different namespace, change the `publisher` field before your first OpenVSX publish.

## 1. Create your OpenVSX account setup

1. Sign in to `https://open-vsx.org` with GitHub.
2. Link your Eclipse account in your OpenVSX profile.
3. Sign the Publisher Agreement.

## 2. Create an access token

Create a token in `https://open-vsx.org/user-settings/tokens` and store it somewhere safe.

Example:

```bash
export OVSX_PAT='paste-your-token-here'
```

## 3. Create the namespace

Run this once per publisher name:

```bash
npx ovsx create-namespace nyc-design -p "$OVSX_PAT"
```

## 4. Publish the extension

From the source folder:

```bash
cd /workspaces/Coder-Workspaces/themes/neil-themes
npx ovsx publish /workspaces/Coder-Workspaces/shared-assets/vscode-themes/neils-themes-0.0.7.vsix -p "$OVSX_PAT"
```

Or publish directly from source:

```bash
cd /workspaces/Coder-Workspaces/themes/neil-themes
npx ovsx publish -p "$OVSX_PAT"
```

## 5. Optional: claim namespace ownership

Namespaces are public by default. If you want the namespace to show as verified, open a claim issue in the OpenVSX website repository:

`https://github.com/EclipseFdn/open-vsx.org/issues`

## Notes

- OpenVSX may reject a publish if automated scanning finds secrets or suspicious files.
- If you bump the extension version in `package.json`, rebuild the `.vsix` before publishing that file.
