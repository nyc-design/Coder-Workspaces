# Neil's Themes

Neil's Themes is a custom VS Code and code-server theme extension with two bundled dark themes:

- `Lunar Dark` for the original neon-forward moonlit palette
- `Solarized Moon` for Solarized Dark workbench colors paired with Lunar Dark syntax highlighting and Python doc-comment enforcement

## Included Themes

- `Lunar Dark`
- `Solarized Moon`

## Development

Package the extension with:

```bash
npx @vscode/vsce package
```

Install the resulting `.vsix` with:

```bash
code-server --install-extension shared-assets/vscode-themes/neils-themes-0.0.7.vsix
```
