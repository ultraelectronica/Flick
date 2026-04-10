use crate::audio::strategy::OutputStrategy;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct OutputVerification {
    pub requested_rate: u32,
    pub actual_rate: u32,
    pub bit_perfect: bool,
    pub resampler_active: bool,
    pub reason: Option<String>,
}

impl OutputVerification {
    pub fn verify(
        requested_rate: u32,
        actual_rate: u32,
        passthrough_requested: bool,
        route_verified: bool,
    ) -> Self {
        if requested_rate != actual_rate {
            return Self {
                requested_rate,
                actual_rate,
                bit_perfect: false,
                resampler_active: true,
                reason: Some(format!(
                    "requested {} Hz, opened {} Hz",
                    requested_rate, actual_rate
                )),
            };
        }

        if passthrough_requested && !route_verified {
            return Self {
                requested_rate,
                actual_rate,
                bit_perfect: false,
                resampler_active: false,
                reason: Some("route verification failed".to_string()),
            };
        }

        Self {
            requested_rate,
            actual_rate,
            bit_perfect: passthrough_requested && route_verified,
            resampler_active: false,
            reason: None,
        }
    }

    pub fn resolved_strategy(&self, selected: OutputStrategy) -> OutputStrategy {
        match selected {
            OutputStrategy::DapNative
            | OutputStrategy::MixerBitPerfect
            | OutputStrategy::UsbDirect
                if !self.bit_perfect =>
            {
                OutputStrategy::ResampledFallback
            }
            OutputStrategy::MixerMatched if self.resampler_active => {
                OutputStrategy::ResampledFallback
            }
            _ => selected,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::OutputVerification;
    use crate::audio::strategy::OutputStrategy;

    #[test]
    fn mismatched_rate_forces_resampler_fallback() {
        let verification = OutputVerification::verify(44_100, 48_000, true, true);

        assert!(verification.resampler_active);
        assert!(!verification.bit_perfect);
        assert_eq!(
            verification.resolved_strategy(OutputStrategy::MixerMatched),
            OutputStrategy::ResampledFallback
        );
    }

    #[test]
    fn verified_exact_match_keeps_passthrough() {
        let verification = OutputVerification::verify(44_100, 44_100, true, true);

        assert!(!verification.resampler_active);
        assert!(verification.bit_perfect);
        assert_eq!(
            verification.resolved_strategy(OutputStrategy::UsbDirect),
            OutputStrategy::UsbDirect
        );
    }

    #[test]
    fn unverified_route_rejects_passthrough() {
        let verification = OutputVerification::verify(44_100, 44_100, true, false);

        assert!(!verification.resampler_active);
        assert!(!verification.bit_perfect);
        assert_eq!(
            verification.reason.as_deref(),
            Some("route verification failed")
        );
        assert_eq!(
            verification.resolved_strategy(OutputStrategy::UsbDirect),
            OutputStrategy::ResampledFallback
        );
    }

    #[test]
    fn exact_match_without_passthrough_request_stays_non_bit_perfect() {
        let verification = OutputVerification::verify(44_100, 44_100, false, true);

        assert!(!verification.resampler_active);
        assert!(!verification.bit_perfect);
        assert_eq!(verification.reason, None);
        assert_eq!(
            verification.resolved_strategy(OutputStrategy::MixerMatched),
            OutputStrategy::MixerMatched
        );
    }
}
