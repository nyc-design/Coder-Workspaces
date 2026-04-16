# Lunar Glass

Lunar Glass is a custom dark theme for VS Code and code-server with a moonlit glass-inspired palette and the original Lunar Glass token colors.

## Included Theme

- `Lunar Glass`

## Development

Package the extension with:

```bash
cd /workspaces/Coder-Workspaces/themes/lunar-glass
npx @vscode/vsce package --out /workspaces/Coder-Workspaces/shared-assets/vscode-themes/lunar-glass-0.0.1.vsix
```

Install the resulting `.vsix` with:

```bash
code-server --install-extension /workspaces/Coder-Workspaces/shared-assets/vscode-themes/lunar-glass-0.0.1.vsix --force
```
