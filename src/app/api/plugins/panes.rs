use ratatui::layout::Direction;
use ratatui::style::Color;
use serde::Serialize;

use super::super::responses::{encode_error, encode_success};
use crate::api::schema::{
    InstalledPluginInfo, PluginInvocationContext, PluginManifestPane, PluginPaneInfo,
    PluginPaneOpenParams, PluginPanePlacement, ResponseResult,
};
use crate::app::App;

#[derive(Serialize)]
struct PluginPaneThemeSnapshot<'a> {
    schema_version: u8,
    name: &'a str,
    palette: PluginPanePaletteSnapshot,
}

#[derive(Serialize)]
struct PluginPanePaletteSnapshot {
    accent: PluginPaneColor,
    panel_bg: PluginPaneColor,
    surface0: PluginPaneColor,
    surface1: PluginPaneColor,
    surface_dim: PluginPaneColor,
    overlay0: PluginPaneColor,
    overlay1: PluginPaneColor,
    text: PluginPaneColor,
    subtext0: PluginPaneColor,
    mauve: PluginPaneColor,
    green: PluginPaneColor,
    yellow: PluginPaneColor,
    red: PluginPaneColor,
    blue: PluginPaneColor,
    teal: PluginPaneColor,
    peach: PluginPaneColor,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum PluginPaneColor {
    Reset,
    Ansi { name: &'static str },
    Indexed { index: u8 },
    Rgb { r: u8, g: u8, b: u8 },
}

impl From<Color> for PluginPaneColor {
    fn from(color: Color) -> Self {
        match color {
            Color::Reset => Self::Reset,
            Color::Black => Self::Ansi { name: "black" },
            Color::Red => Self::Ansi { name: "red" },
            Color::Green => Self::Ansi { name: "green" },
            Color::Yellow => Self::Ansi { name: "yellow" },
            Color::Blue => Self::Ansi { name: "blue" },
            Color::Magenta => Self::Ansi { name: "magenta" },
            Color::Cyan => Self::Ansi { name: "cyan" },
            Color::Gray => Self::Ansi { name: "gray" },
            Color::DarkGray => Self::Ansi { name: "dark_gray" },
            Color::LightRed => Self::Ansi { name: "light_red" },
            Color::LightGreen => Self::Ansi {
                name: "light_green",
            },
            Color::LightYellow => Self::Ansi {
                name: "light_yellow",
            },
            Color::LightBlue => Self::Ansi { name: "light_blue" },
            Color::LightMagenta => Self::Ansi {
                name: "light_magenta",
            },
            Color::LightCyan => Self::Ansi { name: "light_cyan" },
            Color::White => Self::Ansi { name: "white" },
            Color::Indexed(index) => Self::Indexed { index },
            Color::Rgb(r, g, b) => Self::Rgb { r, g, b },
        }
    }
}

impl<'a> PluginPaneThemeSnapshot<'a> {
    fn from_state(state: &'a crate::app::state::AppState) -> Self {
        let palette = &state.palette;
        Self {
            schema_version: 1,
            name: &state.theme_name,
            palette: PluginPanePaletteSnapshot {
                accent: palette.accent.into(),
                panel_bg: palette.panel_bg.into(),
                surface0: palette.surface0.into(),
                surface1: palette.surface1.into(),
                surface_dim: palette.surface_dim.into(),
                overlay0: palette.overlay0.into(),
                overlay1: palette.overlay1.into(),
                text: palette.text.into(),
                subtext0: palette.subtext0.into(),
                mauve: palette.mauve.into(),
                green: palette.green.into(),
                yellow: palette.yellow.into(),
                red: palette.red.into(),
                blue: palette.blue.into(),
                teal: palette.teal.into(),
                peach: palette.peach.into(),
            },
        }
    }
}

impl App {
    pub(super) fn open_plugin_popup_pane(
        &mut self,
        id: String,
        params: PluginPaneOpenParams,
        plugin: &InstalledPluginInfo,
        pane: PluginManifestPane,
    ) -> String {
        let context = self.current_plugin_context("plugin-pane");
        let extra_env =
            match self.plugin_pane_launch_env(plugin, &pane.id, params.env.clone(), &context) {
                Ok(env) => env,
                Err((code, message)) => return encode_error(id, &code, message),
            };
        let cwd = Some(self.plugin_pane_cwd(plugin, params.cwd));
        let width = params.width.or(pane.width);
        let height = params.height.or(pane.height);
        if let Err(err) = self.spawn_popup_argv_command(
            &pane.command,
            cwd,
            extra_env,
            crate::app::popup::PopupGeometry { width, height },
        ) {
            return encode_error(id, "plugin_pane_open_failed", err.to_string());
        }
        let Some(popup) = self.state.popup_pane.as_ref() else {
            return encode_error(id, "plugin_pane_open_failed", "plugin popup disappeared");
        };
        if let Some(terminal) = self.state.terminals.get_mut(&popup.terminal_id) {
            terminal.set_manual_label(pane.title);
        }
        encode_success(id, ResponseResult::Ok {})
    }

    pub(super) fn open_plugin_overlay_pane(
        &mut self,
        id: String,
        params: PluginPaneOpenParams,
        plugin: &InstalledPluginInfo,
        pane: PluginManifestPane,
    ) -> String {
        let context = self.current_plugin_context("plugin-pane");
        let extra_env =
            match self.plugin_pane_launch_env(plugin, &pane.id, params.env.clone(), &context) {
                Ok(env) => env,
                Err((code, message)) => return encode_error(id, &code, message),
            };
        let cwd = Some(self.plugin_pane_cwd(plugin, params.cwd));
        let (ws_idx, new_pane) =
            match self.spawn_overlay_argv_command(&pane.command, cwd, extra_env, Vec::new()) {
                Ok(result) => result,
                Err(err) => return encode_error(id, "plugin_pane_open_failed", err.to_string()),
            };
        let layout_tab_idx = self
            .overlay_panes
            .get(&new_pane.pane_id)
            .map(|overlay| overlay.tab_idx);
        self.finish_plugin_pane_open(
            id,
            ws_idx,
            None,
            layout_tab_idx,
            new_pane,
            plugin.plugin_id.clone(),
            pane,
        )
    }

    pub(super) fn open_plugin_split_pane(
        &mut self,
        id: String,
        params: PluginPaneOpenParams,
        plugin: &InstalledPluginInfo,
        pane: PluginManifestPane,
        placement: PluginPanePlacement,
    ) -> String {
        let target_pane_id = params
            .target_pane_id
            .clone()
            .or_else(|| self.current_public_pane_id());
        let Some(target_pane_id) = target_pane_id else {
            return encode_error(id, "no_active_pane", "no active pane");
        };
        let Some((ws_idx, target_pane)) = self.parse_pane_id(&target_pane_id) else {
            return encode_error(
                id,
                "pane_not_found",
                format!("pane {target_pane_id} not found"),
            );
        };
        let context = self.plugin_context_for_pane(ws_idx, target_pane, "plugin-pane");
        let extra_env =
            match self.plugin_pane_launch_env(plugin, &pane.id, params.env.clone(), &context) {
                Ok(env) => env,
                Err((code, message)) => return encode_error(id, &code, message),
            };
        let direction = match params
            .direction
            .unwrap_or(crate::api::schema::SplitDirection::Right)
        {
            crate::api::schema::SplitDirection::Right => Direction::Horizontal,
            crate::api::schema::SplitDirection::Down => Direction::Vertical,
        };
        let cwd = Some(self.plugin_pane_cwd(plugin, params.cwd));
        let (rows, cols) = self.state.estimate_pane_size();
        let previous_focus = self.state.current_pane_focus_target();
        let Some(ws) = self.state.workspaces.get_mut(ws_idx) else {
            return encode_error(id, "workspace_not_found", "workspace not found");
        };
        let result = ws.split_pane_argv_command(
            target_pane,
            direction,
            rows.max(4),
            cols.max(10),
            cwd,
            &pane.command,
            extra_env,
            self.state.pane_scrollback_limit_bytes,
            self.state.host_terminal_theme,
            params.focus || placement == PluginPanePlacement::Zoomed,
        );
        let (tab_idx, new_pane) = match result {
            Some(Ok(result)) => result,
            Some(Err(err)) => return encode_error(id, "plugin_pane_open_failed", err.to_string()),
            None => {
                return encode_error(
                    id,
                    "pane_not_found",
                    format!("pane {target_pane_id} not found"),
                )
            }
        };
        if params.focus || placement == PluginPanePlacement::Zoomed {
            self.state.switch_workspace_tab(ws_idx, tab_idx);
            self.state
                .record_pane_focus_change(previous_focus, ws_idx, new_pane.pane_id);
            self.state.mode = crate::app::Mode::Terminal;
        }
        if placement == PluginPanePlacement::Zoomed {
            if let Some(tab) = self
                .state
                .workspaces
                .get_mut(ws_idx)
                .and_then(|ws| ws.tabs.get_mut(tab_idx))
            {
                tab.zoomed = true;
            }
        }
        self.finish_plugin_pane_open(
            id,
            ws_idx,
            None,
            Some(tab_idx),
            new_pane,
            plugin.plugin_id.clone(),
            pane,
        )
    }

    pub(super) fn open_plugin_tab(
        &mut self,
        id: String,
        params: PluginPaneOpenParams,
        plugin: &InstalledPluginInfo,
        pane: PluginManifestPane,
    ) -> String {
        let ws_idx = match params.workspace_id.as_deref() {
            Some(workspace_id) => match self.parse_workspace_id(workspace_id) {
                Some(ws_idx) => ws_idx,
                None => return encode_error(id, "workspace_not_found", "workspace not found"),
            },
            None => match self.state.active {
                Some(ws_idx) => ws_idx,
                None => return encode_error(id, "no_active_workspace", "no active workspace"),
            },
        };
        let cwd = self.plugin_pane_cwd(plugin, params.cwd);
        let context = self.plugin_context_for_workspace(ws_idx, "plugin-pane");
        let extra_env =
            match self.plugin_pane_launch_env(plugin, &pane.id, params.env.clone(), &context) {
                Ok(env) => env,
                Err((code, message)) => return encode_error(id, &code, message),
            };
        let (rows, cols) = self.state.estimate_pane_size();
        let Some(ws) = self.state.workspaces.get_mut(ws_idx) else {
            return encode_error(id, "workspace_not_found", "workspace not found");
        };
        let (tab_idx, terminal, runtime) = match ws.create_tab_argv_command(
            rows.max(4),
            cols.max(10),
            cwd,
            &pane.command,
            extra_env,
            self.state.pane_scrollback_limit_bytes,
            self.state.host_terminal_theme,
        ) {
            Ok(result) => result,
            Err(err) => return encode_error(id, "plugin_pane_open_failed", err.to_string()),
        };
        let pane_id = ws.tabs[tab_idx].root_pane;
        if params.focus {
            self.state.switch_workspace_tab(ws_idx, tab_idx);
            self.state.mode = crate::app::Mode::Terminal;
        }
        let new_pane = crate::workspace::NewPane {
            pane_id,
            terminal,
            runtime,
        };
        self.finish_plugin_pane_open(
            id,
            ws_idx,
            Some(tab_idx),
            Some(tab_idx),
            new_pane,
            plugin.plugin_id.clone(),
            pane,
        )
    }

    fn plugin_pane_launch_env(
        &self,
        plugin: &InstalledPluginInfo,
        entrypoint: &str,
        env: std::collections::HashMap<String, String>,
        context: &PluginInvocationContext,
    ) -> Result<Vec<(String, String)>, (String, String)> {
        let mut env = super::super::env::normalize_launch_env(env)?;
        let context_json = serde_json::to_string(&context)
            .map_err(|err| ("invalid_plugin_context".to_string(), err.to_string()))?;
        let theme_json =
            serde_json::to_string(&PluginPaneThemeSnapshot::from_state(&self.state))
                .map_err(|err| ("invalid_plugin_pane_theme".to_string(), err.to_string()))?;
        super::env::ensure_plugin_user_dirs(plugin)
            .map_err(|err| ("plugin_user_dir_create_failed".to_string(), err.to_string()))?;
        env.retain(|(key, _)| !plugin_pane_protected_env_key(key));
        env.extend(super::env::plugin_path_env(plugin));
        env.push((
            crate::api::SOCKET_PATH_ENV_VAR.to_string(),
            crate::api::socket_path().display().to_string(),
        ));
        env.push(("HERDR_ENV".to_string(), "1".to_string()));
        env.push(("HERDR_PLUGIN_ID".to_string(), plugin.plugin_id.clone()));
        env.push((
            "HERDR_PLUGIN_ENTRYPOINT_ID".to_string(),
            entrypoint.to_string(),
        ));
        env.push(("HERDR_PLUGIN_CONTEXT_JSON".to_string(), context_json));
        env.push((super::PLUGIN_PANE_THEME_ENV_VAR.to_string(), theme_json));
        if let Ok(current_exe) = std::env::current_exe() {
            env.push((
                "HERDR_BIN_PATH".to_string(),
                current_exe.display().to_string(),
            ));
        }
        Ok(env)
    }

    fn finish_plugin_pane_open(
        &mut self,
        id: String,
        ws_idx: usize,
        created_tab_idx: Option<usize>,
        layout_tab_idx: Option<usize>,
        new_pane: crate::workspace::NewPane,
        plugin_id: String,
        pane_manifest: PluginManifestPane,
    ) -> String {
        let entrypoint = pane_manifest.id.clone();
        let mut terminal = new_pane.terminal;
        terminal.set_manual_label(pane_manifest.title.clone());
        let terminal_id = terminal.id.clone();
        self.terminal_runtimes
            .insert(terminal_id.clone(), new_pane.runtime);
        self.state
            .remove_alias_shadowed_by_new_pane(new_pane.pane_id);
        self.state.terminals.insert(terminal_id, terminal);
        self.state.plugin_panes.insert(
            new_pane.pane_id,
            crate::app::state::PluginPaneRecord {
                plugin_id: plugin_id.clone(),
                entrypoint: entrypoint.clone(),
            },
        );
        if let Some(tab_idx) = created_tab_idx {
            if let Some(tab) = self.tab_info(ws_idx, tab_idx) {
                self.emit_event(crate::api::schema::EventEnvelope {
                    event: crate::api::schema::EventKind::TabCreated,
                    data: crate::api::schema::EventData::TabCreated { tab },
                });
            }
        }
        self.schedule_session_save();
        let Some(pane) = self.pane_info(ws_idx, new_pane.pane_id) else {
            return encode_error(id, "plugin_pane_open_failed", "plugin pane disappeared");
        };
        self.emit_event(crate::api::schema::EventEnvelope {
            event: crate::api::schema::EventKind::PaneCreated,
            data: crate::api::schema::EventData::PaneCreated { pane: pane.clone() },
        });
        if let Some(tab_idx) = layout_tab_idx {
            self.emit_layout_updated_event(ws_idx, tab_idx);
        }
        encode_success(
            id,
            ResponseResult::PluginPaneOpened {
                plugin_pane: PluginPaneInfo {
                    plugin_id,
                    entrypoint,
                    pane,
                },
            },
        )
    }

    fn plugin_pane_cwd(
        &self,
        plugin: &InstalledPluginInfo,
        override_cwd: Option<String>,
    ) -> std::path::PathBuf {
        override_cwd
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from(&plugin.plugin_root))
    }

    fn current_public_pane_id(&self) -> Option<String> {
        let ws_idx = self.state.active?;
        let pane_id = self.state.workspaces.get(ws_idx)?.focused_pane_id()?;
        self.public_pane_id(ws_idx, pane_id)
    }
}

fn plugin_pane_protected_env_key(key: &str) -> bool {
    matches!(
        key,
        crate::api::SOCKET_PATH_ENV_VAR
            | "HERDR_ENV"
            | "HERDR_PLUGIN_ID"
            | "HERDR_PLUGIN_ROOT"
            | "HERDR_PLUGIN_CONFIG_DIR"
            | "HERDR_PLUGIN_STATE_DIR"
            | "HERDR_PLUGIN_ENTRYPOINT_ID"
            | "HERDR_PLUGIN_CONTEXT_JSON"
            | super::PLUGIN_PANE_THEME_ENV_VAR
            | "HERDR_BIN_PATH"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::state::Palette;

    #[test]
    fn plugin_pane_color_serialization_preserves_every_color_variant() {
        let ansi = [
            (Color::Black, "black"),
            (Color::Red, "red"),
            (Color::Green, "green"),
            (Color::Yellow, "yellow"),
            (Color::Blue, "blue"),
            (Color::Magenta, "magenta"),
            (Color::Cyan, "cyan"),
            (Color::Gray, "gray"),
            (Color::DarkGray, "dark_gray"),
            (Color::LightRed, "light_red"),
            (Color::LightGreen, "light_green"),
            (Color::LightYellow, "light_yellow"),
            (Color::LightBlue, "light_blue"),
            (Color::LightMagenta, "light_magenta"),
            (Color::LightCyan, "light_cyan"),
            (Color::White, "white"),
        ];
        assert_eq!(
            serde_json::to_value(PluginPaneColor::from(Color::Reset)).unwrap(),
            serde_json::json!({"kind": "reset"})
        );
        for (color, name) in ansi {
            assert_eq!(
                serde_json::to_value(PluginPaneColor::from(color)).unwrap(),
                serde_json::json!({"kind": "ansi", "name": name})
            );
        }
        assert_eq!(
            serde_json::to_value(PluginPaneColor::from(Color::Indexed(231))).unwrap(),
            serde_json::json!({"kind": "indexed", "index": 231})
        );
        assert_eq!(
            serde_json::to_value(PluginPaneColor::from(Color::Rgb(1, 2, 3))).unwrap(),
            serde_json::json!({"kind": "rgb", "r": 1, "g": 2, "b": 3})
        );
    }

    #[test]
    fn plugin_pane_theme_serializes_effective_name_and_all_palette_fields() {
        let mut state = crate::app::state::AppState::test_new();
        state.theme_name = "effective-custom".to_string();
        state.palette = Palette {
            accent: Color::Reset,
            panel_bg: Color::Black,
            surface0: Color::Red,
            surface1: Color::Green,
            surface_dim: Color::Yellow,
            overlay0: Color::Blue,
            overlay1: Color::Magenta,
            text: Color::Cyan,
            subtext0: Color::Gray,
            mauve: Color::DarkGray,
            green: Color::LightRed,
            yellow: Color::LightGreen,
            red: Color::LightYellow,
            blue: Color::LightBlue,
            teal: Color::Indexed(42),
            peach: Color::Rgb(7, 8, 9),
        };
        let value = serde_json::to_value(PluginPaneThemeSnapshot::from_state(&state)).unwrap();
        assert_eq!(
            value,
            serde_json::json!({
                "schema_version": 1,
                "name": "effective-custom",
                "palette": {
                    "accent": {"kind":"reset"},
                    "panel_bg": {"kind":"ansi","name":"black"},
                    "surface0": {"kind":"ansi","name":"red"},
                    "surface1": {"kind":"ansi","name":"green"},
                    "surface_dim": {"kind":"ansi","name":"yellow"},
                    "overlay0": {"kind":"ansi","name":"blue"},
                    "overlay1": {"kind":"ansi","name":"magenta"},
                    "text": {"kind":"ansi","name":"cyan"},
                    "subtext0": {"kind":"ansi","name":"gray"},
                    "mauve": {"kind":"ansi","name":"dark_gray"},
                    "green": {"kind":"ansi","name":"light_red"},
                    "yellow": {"kind":"ansi","name":"light_green"},
                    "red": {"kind":"ansi","name":"light_yellow"},
                    "blue": {"kind":"ansi","name":"light_blue"},
                    "teal": {"kind":"indexed","index":42},
                    "peach": {"kind":"rgb","r":7,"g":8,"b":9}
                }
            })
        );
    }

    #[test]
    fn plugin_pane_theme_env_is_protected() {
        assert!(plugin_pane_protected_env_key(
            super::super::PLUGIN_PANE_THEME_ENV_VAR
        ));
    }
}
