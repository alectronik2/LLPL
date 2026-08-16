use std::path::PathBuf;

use zed_extension_api::{self as zed, serde_json::json, LanguageServerId, Worktree};

const SERVER_ID: &str = "llpl-lsp";

struct LlplExtension;

impl LlplExtension {
    fn extension_root() -> zed::Result<PathBuf> {
        std::env::var("PWD")
            .map(PathBuf::from)
            .map_err(|err| format!("failed to resolve extension directory: {err}"))
    }

    fn bundled_server_path() -> zed::Result<String> {
        Ok(Self::extension_root()?
            .join("server")
            .join("out")
            .join("server.js")
            .to_string_lossy()
            .into_owned())
    }

    fn compiler_path(worktree: &Worktree) -> Option<String> {
        for name in ["llpl", "llpl.exe"] {
            if let Some(path) = worktree.which(name) {
                return Some(path);
            }
        }

        let mut dir = PathBuf::from(worktree.root_path());
        loop {
            for name in ["llpl", "llpl.exe"] {
                let candidate = dir.join(name);
                if candidate.exists() {
                    return Some(candidate.to_string_lossy().into_owned());
                }
            }

            if !dir.pop() {
                break;
            }
        }

        None
    }
}

impl zed::Extension for LlplExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> zed::Result<zed::Command> {
        if language_server_id.as_ref() != SERVER_ID {
            return Err(format!("unknown LLPL language server: {language_server_id}"));
        }

        Ok(zed::Command {
            command: zed::node_binary_path()?,
            args: vec![Self::bundled_server_path()?, "--stdio".to_string()],
            env: worktree.shell_env(),
        })
    }

    fn language_server_initialization_options(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> zed::Result<Option<zed::serde_json::Value>> {
        if language_server_id.as_ref() != SERVER_ID {
            return Ok(None);
        }

        Ok(Some(match Self::compiler_path(worktree) {
            Some(compiler_path) => json!({ "compilerPath": compiler_path }),
            None => json!({}),
        }))
    }
}

zed::register_extension!(LlplExtension);
