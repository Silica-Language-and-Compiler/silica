# Silica syntax highlighting for VS Code (and Cursor)

The extension is in `.vscode/extensions/silica-language/` in this directory:

| File | What it does |
| --- | --- |
| `package.json` | Declares the `silica` language for `*.silica` files and its grammar (publisher `silica`, name `silica-language`) |
| `language-configuration.json` | Comments, brackets and auto-closing pairs |
| `syntaxes/silica.tmLanguage.json` | The TextMate grammar used for colouring |
| `cursor_install_colorization.sh` | Installs the extension into Cursor (see below) |

VS Code does not load an extension from a project's `.vscode/extensions/` folder, so leaving the folder in a
project does nothing. Install it once into your editor, using one of the methods below, and it applies to every
`.silica` file you open.

## VS Code: install from the folder (recommended)

1. Open VS Code.
2. Open the Command Palette: Cmd+Shift+P on macOS, Ctrl+Shift+P on Linux and Windows.
3. Run **Developer: Install Extension from Location...**.
4. Choose the folder `editor_support/VSCode/.vscode/extensions/silica-language` in your Silica checkout.
5. Reload when VS Code asks you to, or run **Developer: Reload Window**.

## VS Code: copy the folder by hand

If your VS Code does not have that command, copy the folder into your user extensions directory under the name
VS Code expects, `<publisher>.<name>-<version>`:

```sh
# macOS and Linux, from the root of the Silica checkout
cp -R editor_support/VSCode/.vscode/extensions/silica-language \
      ~/.vscode/extensions/silica.silica-language-0.0.8
```

On Windows the directory is `%USERPROFILE%\.vscode\extensions\`. Quit VS Code completely and start it again;
reloading the window is not always enough for a copied extension. When `package.json`'s `version` changes,
replace the folder and use the new version in its name.

## Cursor

Run the script from the extension folder. It copies the extension into `~/.cursor/extensions/` under its proper
name, removes older installs of it, and registers it in Cursor's `extensions.json`:

```sh
bash editor_support/VSCode/.vscode/extensions/silica-language/cursor_install_colorization.sh
```

Then run **Developer: Reload Window** in Cursor.

## Check that it is active

1. Open any `.silica` file.
2. The language mode in the status bar, bottom right, should read **Silica**. If it reads Plain Text, click it and
   choose Silica; if Silica is not in the list, the extension is not installed.
3. **Developer: Show Running Extensions** lists `silica.silica-language` when it is loaded.

The colours come from your editor's theme; the grammar only names the parts of the language.
