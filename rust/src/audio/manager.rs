use crate::audio::engine::{create_audio_engine, desired_output_signature, AudioEngineHandle};
use parking_lot::Mutex;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::Mutex as AsyncMutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioCapability {
    UsbDac,
    HiResInternal,
    Standard,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioEngine {
    Default,
    Rust,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioCapabilitySnapshot {
    pub capabilities: Vec<AudioCapability>,
    pub route_type: String,
    pub route_label: Option<String>,
    pub max_sample_rate: Option<u32>,
}

impl Default for AudioCapabilitySnapshot {
    fn default() -> Self {
        Self::standard()
    }
}

impl AudioCapabilitySnapshot {
    pub fn standard() -> Self {
        Self {
            capabilities: vec![AudioCapability::Standard],
            route_type: "unknown".to_string(),
            route_label: None,
            max_sample_rate: None,
        }
    }

    pub fn normalize(mut self) -> Self {
        let mut deduped = Vec::with_capacity(self.capabilities.len());
        for capability in self.capabilities {
            if !deduped.contains(&capability) {
                deduped.push(capability);
            }
        }

        deduped.retain(|capability| *capability != AudioCapability::Standard);
        if deduped.is_empty() {
            deduped.push(AudioCapability::Standard);
        } else {
            deduped.sort_by_key(|capability| capability_priority(*capability));
        }

        self.capabilities = deduped;
        self
    }

    pub fn has_capability(&self, capability: AudioCapability) -> bool {
        self.capabilities.contains(&capability)
    }

    pub fn prefers_rust_engine(&self) -> bool {
        self.has_capability(AudioCapability::UsbDac)
            || self.has_capability(AudioCapability::HiResInternal)
    }

    pub fn primary_capability(&self) -> AudioCapability {
        self.capabilities
            .iter()
            .copied()
            .min_by_key(|capability| capability_priority(*capability))
            .unwrap_or(AudioCapability::Standard)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineSelection {
    pub engine: AudioEngine,
    pub primary_capability: AudioCapability,
    pub capabilities: Vec<AudioCapability>,
    pub high_res_mode: bool,
}

struct EngineManagerState {
    current: Option<AudioEngine>,
    rust_handle: Option<AudioEngineHandle>,
    high_res_mode: bool,
    capability_snapshot: AudioCapabilitySnapshot,
}

impl Default for EngineManagerState {
    fn default() -> Self {
        Self {
            current: None,
            rust_handle: None,
            high_res_mode: false,
            capability_snapshot: AudioCapabilitySnapshot::default(),
        }
    }
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

    pub fn set_capability_snapshot(&self, snapshot: AudioCapabilitySnapshot) {
        self.state.lock().capability_snapshot = snapshot.normalize();
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

    pub fn capability_snapshot(
        &self,
        preferred_sample_rate: Option<u32>,
    ) -> Result<AudioCapabilitySnapshot, String> {
        self.runtime
            .block_on(self.capability_snapshot_async(preferred_sample_rate))
    }

    pub fn is_dac_available(&self, preferred_sample_rate: Option<u32>) -> Result<bool, String> {
        self.capability_snapshot(preferred_sample_rate)
            .map(|snapshot| snapshot.has_capability(AudioCapability::UsbDac))
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
        let capability_snapshot = self
            .capability_snapshot_async(preferred_sample_rate)
            .await?;
        Ok(selection_from_snapshot(capability_snapshot, high_res_mode))
    }

    async fn capability_snapshot_async(
        &self,
        preferred_sample_rate: Option<u32>,
    ) -> Result<AudioCapabilitySnapshot, String> {
        let capability_hint = self.state.lock().capability_snapshot.clone();
        tokio::task::spawn_blocking(move || {
            detect_capabilities_blocking(preferred_sample_rate, capability_hint)
        })
        .await
        .map_err(|error| format!("Audio capability detection task failed: {}", error))
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
                "Rust audio engine initialization skipped: no high-capability output path is available and high-res mode is disabled"
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

fn selection_from_snapshot(
    capability_snapshot: AudioCapabilitySnapshot,
    high_res_mode: bool,
) -> EngineSelection {
    EngineSelection {
        engine: if capability_snapshot.prefers_rust_engine() || high_res_mode {
            AudioEngine::Rust
        } else {
            AudioEngine::Default
        },
        primary_capability: capability_snapshot.primary_capability(),
        capabilities: capability_snapshot.capabilities,
        high_res_mode,
    }
}

fn capability_priority(capability: AudioCapability) -> u8 {
    match capability {
        AudioCapability::UsbDac => 0,
        AudioCapability::HiResInternal => 1,
        AudioCapability::Standard => 2,
    }
}

fn detect_capabilities_blocking(
    preferred_sample_rate: Option<u32>,
    capability_hint: AudioCapabilitySnapshot,
) -> AudioCapabilitySnapshot {
    #[cfg(all(feature = "uac2", target_os = "android"))]
    {
        let mut snapshot = capability_hint.normalize();
        if crate::uac2::android_direct_output_signature(preferred_sample_rate).is_some()
            && !snapshot.has_capability(AudioCapability::UsbDac)
        {
            snapshot.capabilities.push(AudioCapability::UsbDac);
        }
        return snapshot.normalize();
    }

    #[cfg(all(feature = "uac2", not(target_os = "android")))]
    {
        let _ = preferred_sample_rate;
        if crate::uac2::enumerate_uac2_devices()
            .map(|devices| !devices.is_empty())
            .unwrap_or(false)
        {
            return AudioCapabilitySnapshot {
                capabilities: vec![AudioCapability::UsbDac],
                route_type: "usb".to_string(),
                route_label: Some("USB DAC".to_string()),
                max_sample_rate: None,
            }
            .normalize();
        }

        return capability_hint.normalize();
    }

    #[cfg(not(feature = "uac2"))]
    {
        let _ = preferred_sample_rate;
        capability_hint.normalize()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        selection_from_snapshot, AudioCapability, AudioCapabilitySnapshot, AudioEngine,
        EngineManager,
    };

    #[test]
    fn init_marks_default_without_loading_rust_engine() {
        let manager = EngineManager::new();
        manager.init();

        assert_eq!(manager.current_engine(), Some(AudioEngine::Default));
        assert!(!manager.is_rust_initialized());
    }

    #[test]
    fn selection_prefers_default_when_only_standard_capability_exists() {
        let selection = selection_from_snapshot(AudioCapabilitySnapshot::standard(), false);
        assert_eq!(selection.engine, AudioEngine::Default);
        assert_eq!(selection.primary_capability, AudioCapability::Standard);
        assert!(!selection.high_res_mode);
    }

    #[test]
    fn selection_prefers_rust_when_high_res_internal_is_detected() {
        let selection = selection_from_snapshot(
            AudioCapabilitySnapshot {
                capabilities: vec![AudioCapability::HiResInternal],
                route_type: "internal".to_string(),
                route_label: Some("HiBy internal DAC".to_string()),
                max_sample_rate: Some(192_000),
            },
            false,
        );
        assert_eq!(selection.engine, AudioEngine::Rust);
        assert_eq!(selection.primary_capability, AudioCapability::HiResInternal);
        assert!(!selection.high_res_mode);
    }

    #[test]
    fn selection_prefers_rust_when_high_res_mode_is_enabled() {
        let selection = selection_from_snapshot(AudioCapabilitySnapshot::standard(), true);
        assert_eq!(selection.engine, AudioEngine::Rust);
        assert_eq!(selection.primary_capability, AudioCapability::Standard);
        assert!(selection.high_res_mode);
    }
}
