# Glaze UI + Auth Fixes (Ver9 format_button)

## Changes

### 1. Message footer action bar (matches your requested layout)
Order left → right:
- Time (gen time)
- Doc / token count (`Nt`)
- **Branch** (icon)
- **Copy** (icon)
- Left / Right arrows (message swipe navigator)
- **Edit** (icon)
- **Delete** (icon)

The three-line (☰) menu button is **removed**.

Pressing the **right arrow** while already on the last swipe of the last message still triggers a **regenerate** into a new variant (existing behavior kept).

### 2. New JS → Flutter handlers
- `copy-message` – copies message text to clipboard in-page
- `edit-message` – starts in-bubble edit
- `delete-message` – confirms then deletes
- `branch` – branches the session at that message

### 3. Files touched
- `assets/chat_webview/renderer/icon_library.js` – added `branch` icon
- `assets/chat_webview/renderer/message_renderer.js` – inline buttons in footer
- `assets/chat_webview/bridge/interaction_dispatch.js` – action handlers
- `assets/chat_webview/styles.css` – styles for `.msg-inline-btn` / `.msg-right-actions`
- `lib/features/chat/bridge/bridge_handlers.dart`
- `lib/features/chat/bridge/chat_bridge_controller.dart`
- `lib/features/chat/widgets/webview_callbacks.dart`
- `lib/features/chat/widgets/chat_webview_callbacks.dart`
- `lib/features/chat/widgets/chat_webview_widget.dart`
- `lib/features/chat/chat_screen.dart`

### 4. How to apply
Copy the files from this patch over the corresponding paths in your full Glaze tree, then rebuild.

### 5. SpicyChat sign-in persistence
The login sheet still intentionally wipes cookies on a *fresh* sign-in (see `spicychat_login_sheet.dart` `_prepare`).  
If the account is forgotten *after* a successful login, the bug is in session snapshot save/restore (`SpicyChatSessionSnapshot` / `spicyChatAccountProvider`).  
That path was not changed in this patch; open a follow-up if the restore path is still dropping the session.

### 6. Token / character count
Token count (`Nt`) continues to come from the message’s `tokens` field.  
Character count is not stored on the message map today; if you want `Nc` shown next to tokens, we can compute `content.length` in the renderer in a follow-up.

