//! Build identity helpers.

pub const BASE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn channel() -> &'static str {
    non_empty(option_env!("HERDR_BUILD_CHANNEL")).unwrap_or("stable")
}

pub fn build_id() -> Option<&'static str> {
    non_empty(option_env!("HERDR_BUILD_ID"))
}

pub fn version() -> String {
    format_version(BASE_VERSION, channel(), build_id())
}

pub fn is_preview() -> bool {
    channel() == "preview"
}

fn format_version(base_version: &str, channel: &str, build_id: Option<&str>) -> String {
    match channel {
        "stable" => base_version.to_string(),
        channel => match build_id {
            Some(build_id) => format!("{base_version}-{channel}.{build_id}"),
            None => format!("{base_version}-{channel}"),
        },
    }
}

fn non_empty(value: Option<&'static str>) -> Option<&'static str> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::format_version;

    #[test]
    fn stable_version_defaults_to_cargo_version() {
        assert!(!super::version().is_empty());
    }

    #[test]
    fn formats_official_and_downstream_build_identities() {
        assert_eq!(format_version("0.7.5", "stable", None), "0.7.5");
        assert_eq!(
            format_version("0.7.5", "preview", Some("abc123")),
            "0.7.5-preview.abc123"
        );
        assert_eq!(format_version("0.7.5", "akram", Some("1")), "0.7.5-akram.1");
    }
}
