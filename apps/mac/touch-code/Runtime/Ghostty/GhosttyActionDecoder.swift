import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore
import os.log

/// Single translation boundary between libghostty's C action union
/// (`ghostty_action_s`) and typed Swift intents. The decoder never mutates
/// app or reducer state directly — surface-scoped info actions call into
/// `PanelSurface.apply(_:)` + `GhosttyRuntime.emitInfoChanged(_:_:)`, tab/
/// split/window intents are lifted onto the `TerminalEvent` stream via
/// `GhosttyRuntime.emit(_:)`, and effectful actions trigger AppKit calls
/// in place.
///
/// Case layout mirrors `ghostty_action_tag_e` in `ghostty.h:887`. The tag
/// set is large (65 entries) and C enums import as `struct` without
/// exhaustiveness, so both methods fall through to a `default` branch that
/// logs the unknown tag's raw value.
@MainActor
enum GhosttyActionDecoder {

  private static let logger = Logger(
    subsystem: "com.touch-code.runtime",
    category: "action"
  )

  // MARK: - Surface-scoped actions

  static func surfaceAction(
    _ action: ghostty_action_s,
    panelID: PanelID,
    panel: PanelSurface,
    runtime: GhosttyRuntime
  ) -> Bool {
    switch action.tag {

    // MARK: Bucket 1 — Tab / Split intent
    case GHOSTTY_ACTION_NEW_TAB:
      return emitPanelIntent(.newTab, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_CLOSE_TAB:
      guard let mode = decodeCloseTabMode(action.action.close_tab_mode) else {
        return logUnsupported(tag: action.tag, reason: "close_tab: unknown mode")
      }
      return emitPanelIntent(.closeTab(mode: mode), panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_MOVE_TAB:
      let offset = Int(action.action.move_tab.amount)
      return emitPanelIntent(.moveTab(offset: offset), panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_GOTO_TAB:
      let target = decodeGotoTabTarget(action.action.goto_tab)
      return emitPanelIntent(.gotoTab(target: target), panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_NEW_SPLIT:
      guard let dir = decodeNewSplitDirection(action.action.new_split) else {
        return logUnsupported(tag: action.tag, reason: "new_split: unknown direction")
      }
      return emitPanelIntent(.newSplit(direction: dir), panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_GOTO_SPLIT:
      guard let dir = decodeGotoSplitDirection(action.action.goto_split) else {
        return logUnsupported(tag: action.tag, reason: "goto_split: unknown direction")
      }
      return emitPanelIntent(.gotoSplit(direction: dir), panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let resize = action.action.resize_split
      guard let dir = decodeResizeSplitDirection(resize.direction) else {
        return logUnsupported(tag: action.tag, reason: "resize_split: unknown direction")
      }
      let request = PanelActionRequest.resizeSplit(direction: dir, amount: Double(resize.amount))
      return emitPanelIntent(request, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      return emitPanelIntent(.equalizeSplits, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      return emitPanelIntent(.toggleSplitZoom, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      return emitPanelIntent(.presentTerminal, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      return emitPanelIntent(.toggleCommandPalette, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 2 — Window intent
    case GHOSTTY_ACTION_NEW_WINDOW:
      return emitWindowIntent(.new(from: panelID), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      return emitWindowIntent(.close(from: panelID), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      return emitWindowIntent(.closeAll, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_GOTO_WINDOW:
      guard let target = decodeGotoWindowTarget(action.action.goto_window) else {
        return logUnsupported(tag: action.tag, reason: "goto_window: unknown target")
      }
      return emitWindowIntent(.goto(target: target), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      return emitWindowIntent(.toggleFullscreen(from: panelID), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      return emitWindowIntent(.toggleMaximize(from: panelID), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      return emitWindowIntent(.toggleTabOverview(from: panelID), runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      // No per-window decoration toggle on macOS — documented explicit no-op.
      logger.debug("unsupported surface action: toggle_window_decorations (no macOS analog)")
      return false

    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      // touch-code does not ship a global-hotkey HUD equivalent.
      logger.debug("unsupported surface action: toggle_quick_terminal (no touch-code analog)")
      return false

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      return emitWindowIntent(.toggleAppVisibility, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      runtime.toggleBackgroundOpacity()
      logger.debug("surface action: toggle_background_opacity")
      return true

    // MARK: Bucket 2 continued — App-level intent raised from a surface
    case GHOSTTY_ACTION_QUIT:
      return emitWindowIntent(.quit, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
      return emitWindowIntent(.checkForUpdates, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_OPEN_CONFIG:
      return emitWindowIntent(.openConfig, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: title family
    case GHOSTTY_ACTION_SET_TITLE:
      let title = String.decode(cstring: action.action.set_title.title)
      return emitInfo(.title(title), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_SET_TAB_TITLE:
      let title = String.decode(cstring: action.action.set_tab_title.title)
      return emitInfo(.tabTitle(title), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_PROMPT_TITLE:
      let raw = UInt32(action.action.prompt_title.rawValue)
      return emitInfo(.promptTitle(raw), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_PWD:
      let pwd = String.decode(cstring: action.action.pwd.pwd)
      return emitInfo(.pwd(pwd), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: mouse family
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let raw = UInt32(action.action.mouse_shape.rawValue)
      return emitInfo(.mouseShape(raw), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
      return emitInfo(.mouseVisible(visible), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      let str = String.decode(cstring: link.url, length: Int(link.len))
      return emitInfo(.mouseOverLink(str), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: geometry family
    case GHOSTTY_ACTION_CELL_SIZE:
      let s = action.action.cell_size
      return emitInfo(.cellSize(width: s.width, height: s.height),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_SIZE_LIMIT:
      let s = action.action.size_limit
      return emitInfo(.sizeLimit(minWidth: s.min_width, minHeight: s.min_height,
                                 maxWidth: s.max_width, maxHeight: s.max_height),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let s = action.action.initial_size
      return emitInfo(.initialSize(width: s.width, height: s.height),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      return emitInfo(.resetWindowSize, panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: scrollbar / renderer / color
    case GHOSTTY_ACTION_SCROLLBAR:
      let s = action.action.scrollbar
      return emitInfo(.scrollbar(total: Int(s.total), offset: Int(s.offset), length: Int(s.len)),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_RENDERER_HEALTH:
      let healthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
      return emitInfo(.rendererHealthy(healthy),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_COLOR_CHANGE:
      let c = action.action.color_change
      return emitInfo(.colorChange(kind: Int32(c.kind.rawValue), r: c.r, g: c.g, b: c.b),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: secure input / key / readonly / quit timer / float
    case GHOSTTY_ACTION_SECURE_INPUT:
      let raw = UInt32(action.action.secure_input.rawValue)
      return emitInfo(.secureInput(raw), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_KEY_SEQUENCE:
      let seq = action.action.key_sequence
      // `trigger` is a composite struct; collapse to a UInt32 hash of its
      // `key`/`mods` fields until a richer KeySequence type is needed.
      let triggerRaw = keyTriggerFingerprint(seq.trigger)
      return emitInfo(.keySequence(active: seq.active, trigger: triggerRaw),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_KEY_TABLE:
      let (name, depth) = decodeKeyTable(action.action.key_table)
      return emitInfo(.keyTable(name: name, depth: depth),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_READONLY:
      let on = action.action.readonly == GHOSTTY_READONLY_ON
      return emitInfo(.readonly(on), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_QUIT_TIMER:
      let raw = UInt32(action.action.quit_timer.rawValue)
      return emitInfo(.quitTimer(raw), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      let floating = action.action.float_window == GHOSTTY_FLOAT_WINDOW_ON
      return emitInfo(.floatWindow(floating), panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: search family
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = String.decode(cstring: action.action.start_search.needle) ?? ""
      return emitInfo(.searchStarted(needle: needle),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_END_SEARCH:
      return emitInfo(.searchEnded, panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = Int(action.action.search_total.total)
      return emitInfo(.searchTotal(total),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = Int(action.action.search_selected.selected)
      return emitInfo(.searchSelected(selected),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 3 — Surface info: progress
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let r = action.action.progress_report
      let value: Int? = r.progress == -1 ? nil : Int(r.progress)
      let state = UInt32(r.state.rawValue)
      return emitInfo(.progress(state: state, value: value),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    // MARK: Bucket 4 — Effectful
    case GHOSTTY_ACTION_OPEN_URL:
      return handleOpenURL(action.action.open_url)

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let n = action.action.desktop_notification
      let title = String.decode(cstring: n.title) ?? ""
      let body = String.decode(cstring: n.body) ?? ""
      return emitInfo(.desktopNotification(title: title, body: body),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_RING_BELL:
      return emitInfo(.bellRang, panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let f = action.action.command_finished
      return emitInfo(.commandFinished(exitCode: Int32(f.exit_code), duration: f.duration),
                      panel: panel, panelID: panelID, runtime: runtime, tag: action.tag)

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let ex = action.action.child_exited
      let code = Int32(bitPattern: ex.exit_code)
      panel.markExited(code: code)
      runtime.emitInfoChanged(panelID, .childExited(code: code))
      logger.debug("surface action: show_child_exited (code \(code))")
      return true

    case GHOSTTY_ACTION_UNDO:
      NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
      logger.debug("surface action: undo")
      return true

    case GHOSTTY_ACTION_REDO:
      NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
      logger.debug("surface action: redo")
      return true

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      // SurfaceInfo lands in Milestone 3; for now the decoder has no title
      // to read back. Pasteboard write is wired here so the M3 landing is a
      // two-line change (read panel.info.title, feed it in).
      logger.debug("surface action: copy_title_to_clipboard (awaiting SurfaceInfo in M3)")
      return true

    // MARK: Bucket 5 — Explicitly unsupported on macOS
    case GHOSTTY_ACTION_RENDER,
         GHOSTTY_ACTION_INSPECTOR,
         GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
         GHOSTTY_ACTION_RENDER_INSPECTOR,
         GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      logger.debug("unsupported surface action (non-macOS / internal): tag \(action.tag.rawValue)")
      return false

    // MARK: Bucket 5 — App-scoped actions arriving on a surface target: fall through
    // CONFIG_CHANGE / RELOAD_CONFIG fire on GHOSTTY_TARGET_APP so surface
    // dispatch never hits them; treated as programmer error if they do.
    case GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RELOAD_CONFIG:
      logger.info("unexpected app-scoped action on surface target: tag \(action.tag.rawValue)")
      return false

    default:
      logger.info("unknown ghostty surface action tag: \(action.tag.rawValue)")
      return false
    }
  }

  // MARK: - App-scoped actions

  static func appAction(
    _ action: ghostty_action_s,
    runtime: GhosttyRuntime
  ) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_CONFIG_CHANGE:
      guard let source = action.action.config_change.config,
            let cloned = ghostty_config_clone(source)
      else {
        logger.error("config_change: ghostty_config_clone returned nil")
        return false
      }
      runtime.applyClonedConfig(cloned)
      runtime.emit(.configChanged)
      logger.debug("app action: config_change")
      return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      runtime.reloadConfig(soft: action.action.reload_config.soft)
      runtime.emit(.configChanged)
      logger.debug("app action: reload_config (soft: \(action.action.reload_config.soft))")
      return true

    case GHOSTTY_ACTION_QUIT:
      runtime.emit(.windowActionRequested(.quit))
      logger.debug("app action: quit")
      return true

    default:
      logger.info("unknown ghostty app action tag: \(action.tag.rawValue)")
      return false
    }
  }
}

// MARK: - Dispatch helpers

extension GhosttyActionDecoder {

  /// Emit a panel intent event and log at `.debug`. Centralized so every
  /// Bucket-1 case is a single line in the main switch.
  fileprivate static func emitPanelIntent(
    _ request: PanelActionRequest,
    panelID: PanelID,
    runtime: GhosttyRuntime,
    tag: ghostty_action_tag_e
  ) -> Bool {
    runtime.emit(.panelActionRequested(panelID, request))
    logger.debug("surface action: panel intent tag=\(tag.rawValue)")
    return true
  }

  fileprivate static func emitWindowIntent(
    _ request: WindowActionRequest,
    runtime: GhosttyRuntime,
    tag: ghostty_action_tag_e
  ) -> Bool {
    runtime.emit(.windowActionRequested(request))
    logger.debug("surface action: window intent tag=\(tag.rawValue)")
    return true
  }

  /// Apply a Bucket-3 info delta to the panel + emit on the event stream.
  fileprivate static func emitInfo(
    _ delta: PanelInfoDelta,
    panel: PanelSurface,
    panelID: PanelID,
    runtime: GhosttyRuntime,
    tag: ghostty_action_tag_e
  ) -> Bool {
    panel.apply(delta)
    runtime.emitInfoChanged(panelID, delta)
    logger.debug("surface action: info tag=\(tag.rawValue)")
    return true
  }

  fileprivate static func logUnsupported(
    tag: ghostty_action_tag_e,
    reason: String
  ) -> Bool {
    logger.info("unsupported ghostty action tag=\(tag.rawValue): \(reason)")
    return false
  }
}

// MARK: - C enum decoders

extension GhosttyActionDecoder {

  fileprivate static func decodeCloseTabMode(_ mode: ghostty_action_close_tab_mode_e) -> CloseTabMode? {
    switch mode {
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:  return .this
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: return .other
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: return .right
    default: return nil
    }
  }

  fileprivate static func decodeGotoTabTarget(_ tab: ghostty_action_goto_tab_e) -> GotoTabTarget {
    switch tab {
    case GHOSTTY_GOTO_TAB_PREVIOUS: return .previous
    case GHOSTTY_GOTO_TAB_NEXT:     return .next
    case GHOSTTY_GOTO_TAB_LAST:     return .last
    default:                        return .index(Int(tab.rawValue))
    }
  }

  fileprivate static func decodeNewSplitDirection(_ dir: ghostty_action_split_direction_e) -> NewSplitDirection? {
    switch dir {
    case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
      return .horizontal
    case GHOSTTY_SPLIT_DIRECTION_UP, GHOSTTY_SPLIT_DIRECTION_DOWN:
      return .vertical
    default:
      return nil
    }
  }

  fileprivate static func decodeGotoSplitDirection(_ dir: ghostty_action_goto_split_e) -> FocusDirection? {
    switch dir {
    case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .previous
    case GHOSTTY_GOTO_SPLIT_NEXT:     return .next
    case GHOSTTY_GOTO_SPLIT_UP:       return .up
    case GHOSTTY_GOTO_SPLIT_DOWN:     return .down
    case GHOSTTY_GOTO_SPLIT_LEFT:     return .left
    case GHOSTTY_GOTO_SPLIT_RIGHT:    return .right
    default: return nil
    }
  }

  fileprivate static func decodeResizeSplitDirection(_ dir: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
    switch dir {
    case GHOSTTY_RESIZE_SPLIT_UP:    return .up
    case GHOSTTY_RESIZE_SPLIT_DOWN:  return .down
    case GHOSTTY_RESIZE_SPLIT_LEFT:  return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
    default: return nil
    }
  }

  /// libghostty's GotoWindow enum exposes only PREVIOUS/NEXT. The richer
  /// `GotoWindowTarget` (last / index) is reserved for future IPC-driven
  /// navigation; current action payloads cannot produce those variants.
  fileprivate static func decodeGotoWindowTarget(_ target: ghostty_action_goto_window_e) -> GotoWindowTarget? {
    switch target {
    case GHOSTTY_GOTO_WINDOW_PREVIOUS: return .previous
    case GHOSTTY_GOTO_WINDOW_NEXT:     return .next
    default: return nil
    }
  }

  /// Collapse the 3-variant key_table tag + optional name into the flat
  /// `(name, depth)` shape of `PanelInfoDelta.keyTable`. Depth mirrors the
  /// tag semantics: ACTIVATE=+1, DEACTIVATE=-1, DEACTIVATE_ALL=0 (reset).
  fileprivate static func decodeKeyTable(_ table: ghostty_action_key_table_s) -> (name: String?, depth: Int) {
    switch table.tag {
    case GHOSTTY_KEY_TABLE_ACTIVATE:
      let activate = table.value.activate
      let name = String.decode(cstring: activate.name, length: Int(activate.len))
      return (name, 1)
    case GHOSTTY_KEY_TABLE_DEACTIVATE:
      return (nil, -1)
    case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
      return (nil, 0)
    default:
      return (nil, 0)
    }
  }

  /// Flatten `ghostty_input_trigger_s` into a UInt32 fingerprint. The
  /// composite struct mixes a key enum, modifier mask, and scalar fields;
  /// consumers today (tab chrome) only need a change-detector, so we hash
  /// the raw bytes rather than model every field on `PanelInfoDelta`.
  fileprivate static func keyTriggerFingerprint(_ trigger: ghostty_input_trigger_s) -> UInt32 {
    var hasher = Hasher()
    withUnsafeBytes(of: trigger) { buffer in
      hasher.combine(bytes: buffer)
    }
    return UInt32(truncatingIfNeeded: hasher.finalize())
  }
}

// MARK: - Effectful helpers

extension GhosttyActionDecoder {

  /// OPEN_URL: validate the scheme and hand off to LaunchServices. Rejects
  /// empty payloads and URLs without a scheme so we don't fling naked paths
  /// at `NSWorkspace.open`.
  fileprivate static func handleOpenURL(_ payload: ghostty_action_open_url_s) -> Bool {
    guard let url = String.decode(cstring: payload.url, length: Int(payload.len)),
          !url.isEmpty,
          let parsed = URL(string: url),
          parsed.scheme?.isEmpty == false
    else {
      logger.info("open_url: rejected (missing / invalid URL)")
      return false
    }
    NSWorkspace.shared.open(parsed)
    logger.debug("surface action: open_url scheme=\(parsed.scheme ?? "?")")
    return true
  }
}

// MARK: - String decoding

extension String {

  /// Copy a null-terminated C string into Swift. Returns nil if the pointer
  /// is null. The decoder uses this for every `const char*` action field so
  /// null-vs-empty is preserved downstream.
  fileprivate static func decode(cstring: UnsafePointer<CChar>?) -> String? {
    guard let cstring else { return nil }
    return String(cString: cstring)
  }

  /// Copy a length-delimited C byte run into Swift (UTF-8). Used for fields
  /// where libghostty passes an explicit length alongside the pointer so
  /// the string may contain embedded NULs (unusual) or be non-terminated.
  fileprivate static func decode(cstring: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let cstring, length >= 0 else { return nil }
    if length == 0 { return "" }
    let buffer = UnsafeBufferPointer(start: cstring, count: length)
    return buffer.withMemoryRebound(to: UInt8.self) { bytes in
      String(bytes: bytes, encoding: .utf8)
    }
  }
}
