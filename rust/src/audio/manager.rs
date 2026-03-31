use crate::audio::engine::{create_audio_engine, desired_output_signature, AudioEngineHandle};
use parking_lot::Mutex;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::Mutex as AsyncMutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioEngine {
    Default,
    Rust,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineSelection {
    pub engine: AudioEngine,
    pub dac_detected: bool,
    pub high_res_mode: bool,
}

#[derive(Default)]
struct EngineManagerState {
    current: Option<AudioEngine>,
    rust_handle: Option<AudioEngineHandle>,
    high_res_mode: bool,
}

pub struct EngineManager {
    runtime: Runtime,
    init_gate: AsyncMutex<()>,
    state: Mutex<EngineManagerState>,
}

impl EngineManager {
    pub fn new() -> Self {
        let runtime = Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("audio-engine-manager")
            .enable_all()
            .build()
            .expect("failed to create engine manager runtime");

        Self {
            runtime,
            init_gate: AsyncMutex::new(()),
            state: Mutex::new(EngineManagerState::default()),
        }
    }

    pub fn init(&self) {
        let mut state = self.state.lock();
        if state.current.is_none() {
            state.current = Some(AudioEngine::Default);
        }
    }

    pub fn set_high_res_mode(&self, enabled: bool) {
        let mut state = self.state.lock();
        state.high_res_mode = enabled;
        if !enabled && state.rust_handle.is_none() {
            state.current = Some(AudioEngine::Default);
        }
    }

    pub fn current_engine(&self) -> Option<AudioEngine> {
        self.state.lock().current
    }

    pub fn is_rust_initialized(&self) -> bool {
        self.state.lock().rust_handle.is_some()
    }

    pub fn selection(&self, preferred_sample_rate: Option<u32>) -> Result<EngineSelection, String> {
        self.runtime
            .block_on(self.selection_async(preferred_sample_rate))
    }

    pub fn is_dac_available(&self, preferred_sample_rate: Option<u32>) -> Result<bool, String> {
        self.selection(preferred_sample_rate)
            .map(|selection| selection.dac_detected)
    }

    pub fn ensure_rust_engine(&self, preferred_sample_rate: Option<u32>) -> Result<(), String> {
        self.runtime
            .block_on(self.ensure_rust_engine_async(preferred_sample_rate))
    }

    pub fn with_rust_handle<T>(
        &self,
        f: impl FnOnce(&AudioEngineHandle) -> Result<T, String>,
    ) -> Result<T, String> {
        let state = self.state.lock();
        let handle = state
            .rust_handle
            .as_ref()
            .ok_or_else(|| "Rust audio engine is not initialized".to_string())?;
        f(handle)
    }

    pub fn read_rust_handle<T>(&self, f: impl FnOnce(&AudioEngineHandle) -> T) -> Option<T> {
        let state = self.state.lock();
        state.rust_handle.as_ref().map(f)
    }

    pub fn shutdown(&self) -> Result<(), String> {
        self.runtime.block_on(self.shutdown_async())
    }

    async fn selection_async(
        &self,
        preferred_sample_rate: Option<u32>,
    ) -> Result<EngineSelection, String> {
        let high_res_mode = self.state.lock().high_res_mode;
        let dac_detected =
            tokio::task::spawn_blocking(move || detect_dac_blocking(preferred_sample_rate))
                .await
                .map_err(|error| format!("DAC detection task failed: {}", error))?;

        Ok(selection_from_flags(dac_detected, high_res_mode))
    }

    async fn ensure_rust_engine_async(
        &self,
        preferred_sample_rate: Option<u32>,
    ) -> Result<(), String> {
        let _gate = self.init_gate.lock().await;
        let selection = self.selection_async(preferred_sample_rate).await?;

        if selection.engine != AudioEngine::Rust {
            self.state.lock().current = Some(AudioEngine::Default);
            return Err(
                "Rust audio engine initialization skipped: no DAC detected and high-res mode is disabled"
                    .to_string(),
            );
        }

        let desired_signature = desired_output_signature(preferred_sample_rate);
        {
            let mut state = self.state.lock();
            let should_reuse = state
                .rust_handle
                .as_ref()
                .is_some_and(|handle| handle.output_signature() == desired_signature);

            if should_reuse {
                state.current = Some(AudioEngine::Rust);
                return Ok(());
            }
        }

        let previous_handle = {
            let mut state = self.state.lock();
            state.current = None;
            state.rust_handle.take()
        };

        if let Some(handle) = previous_handle {
            tokio::task::spawn_blocking(move || handle.shutdown())
                .await
                .map_err(|error| format!("Existing engine shutdown task failed: {}", error))??;
        }

        let new_handle =
            tokio::task::spawn_blocking(move || create_audio_engine(preferred_sample_rate))
                .await
                .map_err(|error| format!("Rust engine initialization task failed: {}", error))??;

        let mut state = self.state.lock();
        state.current = Some(AudioEngine::Rust);
        state.rust_handle = Some(new_handle);
        Ok(())
    }

    async fn shutdown_async(&self) -> Result<(), String> {
        let _gate = self.init_gate.lock().await;
        let previous_handle = {
            let mut state = self.state.lock();
            state.current = None;
            state.rust_handle.take()
        };

        if let Some(handle) = previous_handle {
            tokio::task::spawn_blocking(move || handle.shutdown())
                .await
                .map_err(|error| format!("Rust engine shutdown task failed: {}", error))??;
        }

        Ok(())
    }
}

fn selection_from_flags(dac_detected: bool, high_res_mode: bool) -> EngineSelection {
    EngineSelection {
        engine: if dac_detected || high_res_mode {
            AudioEngine::Rust
        } else {
            AudioEngine::Default
        },
        dac_detected,
        high_res_mode,
    }
}

fn detect_dac_blocking(preferred_sample_rate: Option<u32>) -> bool {
    #[cfg(all(feature = "uac2", target_os = "android"))]
    {
        return crate::uac2::android_direct_output_signature(preferred_sample_rate).is_some();
    }

    #[cfg(all(feature = "uac2", not(target_os = "android")))]
    {
        let _ = preferred_sample_rate;
        return crate::uac2::enumerate_uac2_devices()
            .map(|devices| !devices.is_empty())
            .unwrap_or(false);
    }

    #[cfg(not(feature = "uac2"))]
    {
        let _ = preferred_sample_rate;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::{selection_from_flags, AudioEngine, EngineManager};

    #[test]
    fn init_marks_default_without_loading_rust_engine() {
        let manager = EngineManager::new();
        manager.init();

        assert_eq!(manager.current_engine(), Some(AudioEngine::Default));
        assert!(!manager.is_rust_initialized());
    }

    #[test]
    fn selection_prefers_default_when_no_dac_and_high_res_is_off() {
        let selection = selection_from_flags(false, false);
        assert_eq!(selection.engine, AudioEngine::Default);
        assert!(!selection.dac_detected);
        assert!(!selection.high_res_mode);
    }

    #[test]
    fn selection_prefers_rust_when_high_res_is_enabled() {
        let selection = selection_from_flags(false, true);
        assert_eq!(selection.engine, AudioEngine::Rust);
        assert!(!selection.dac_detected);
        assert!(selection.high_res_mode);
    }
}
