use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, FormatType, SampleRate};
use crate::uac2::capabilities::{ControlCapabilities, DeviceCapabilities, DeviceType, PowerCapabilities};
use crate::uac2::device_classifier::{AudioRequirements, DeviceClassifier, DeviceMatchingLogic, FormatClass, PowerClass};

#[test]
fn test_classify_by_format_standard() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let class = DeviceClassifier::classify_by_format(&formats);
    assert_eq!(class, FormatClass::Standard);
}

#[test]
fn test_classify_by_format_hi_res() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(96000).unwrap()],
            BitDepth::Bits24,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let class = DeviceClassifier::classify_by_format(&formats);
    assert_eq!(class, FormatClass::HiRes);
}

#[test]
fn test_classify_by_format_dsd() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(352800).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Dsd,
        ).unwrap(),
    ];
    
    let class = DeviceClassifier::classify_by_format(&formats);
    assert_eq!(class, FormatClass::Dsd);
}

#[test]
fn test_classify_by_format_empty() {
    let formats = vec![];
    let class = DeviceClassifier::classify_by_format(&formats);
    assert_eq!(class, FormatClass::Unknown);
}

#[test]
fn test_classify_by_power() {
    assert_eq!(DeviceClassifier::classify_by_power(50), PowerClass::Low);
    assert_eq!(DeviceClassifier::classify_by_power(100), PowerClass::Low);
    assert_eq!(DeviceClassifier::classify_by_power(101), PowerClass::Medium);
    assert_eq!(DeviceClassifier::classify_by_power(500), PowerClass::Medium);
    assert_eq!(DeviceClassifier::classify_by_power(501), PowerClass::High);
    assert_eq!(DeviceClassifier::classify_by_power(1000), PowerClass::High);
}

#[test]
fn test_audio_requirements_builder() {
    let requirements = AudioRequirements::new()
        .with_sample_rate(SampleRate::new(48000).unwrap())
        .with_bit_depth(BitDepth::Bits24)
        .with_device_type(DeviceType::DacOnly);
    
    assert_eq!(requirements.min_sample_rate.unwrap().hz(), 48000);
    assert_eq!(requirements.min_bit_depth.unwrap().bits(), 24);
    assert_eq!(requirements.device_type.unwrap(), DeviceType::DacOnly);
}

#[test]
fn test_device_matching_meets_requirements() {
    let device = DeviceCapabilities {
        device_type: DeviceType::DacOnly,
        supported_formats: vec![],
        max_sample_rate: Some(SampleRate::new(96000).unwrap()),
        max_bit_depth: Some(BitDepth::Bits24),
        max_channels: Some(ChannelConfig::Stereo),
        power: PowerCapabilities {
            max_power_ma: 500,
            self_powered: false,
        },
        controls: ControlCapabilities {
            has_volume: true,
            has_mute: true,
            has_bass: false,
            has_treble: false,
            has_eq: false,
        },
        feature_units: vec![],
        input_terminals: vec![],
        output_terminals: vec![],
    };
    
    let requirements = AudioRequirements::new()
        .with_sample_rate(SampleRate::new(48000).unwrap())
        .with_bit_depth(BitDepth::Bits16);
    
    let devices = vec![device];
    let result = DeviceMatchingLogic::find_best_match(&devices, &requirements);
    assert!(result.is_some());
}

#[test]
fn test_device_matching_fails_requirements() {
    let device = DeviceCapabilities {
        device_type: DeviceType::DacOnly,
        supported_formats: vec![],
        max_sample_rate: Some(SampleRate::new(48000).unwrap()),
        max_bit_depth: Some(BitDepth::Bits16),
        max_channels: Some(ChannelConfig::Stereo),
        power: PowerCapabilities {
            max_power_ma: 500,
            self_powered: false,
        },
        controls: ControlCapabilities {
            has_volume: true,
            has_mute: true,
            has_bass: false,
            has_treble: false,
            has_eq: false,
        },
        feature_units: vec![],
        input_terminals: vec![],
        output_terminals: vec![],
    };
    
    let requirements = AudioRequirements::new()
        .with_sample_rate(SampleRate::new(96000).unwrap())
        .with_bit_depth(BitDepth::Bits24);
    
    let devices = vec![device];
    let result = DeviceMatchingLogic::find_best_match(&devices, &requirements);
    assert!(result.is_none());
}

#[test]
fn test_device_matching_best_of_multiple() {
    let device1 = DeviceCapabilities {
        device_type: DeviceType::DacOnly,
        supported_formats: vec![],
        max_sample_rate: Some(SampleRate::new(48000).unwrap()),
        max_bit_depth: Some(BitDepth::Bits16),
        max_channels: Some(ChannelConfig::Stereo),
        power: PowerCapabilities {
            max_power_ma: 500,
            self_powered: false,
        },
        controls: ControlCapabilities {
            has_volume: true,
            has_mute: true,
            has_bass: false,
            has_treble: false,
            has_eq: false,
        },
        feature_units: vec![],
        input_terminals: vec![],
        output_terminals: vec![],
    };
    
    let device2 = DeviceCapabilities {
        device_type: DeviceType::DacOnly,
        supported_formats: vec![],
        max_sample_rate: Some(SampleRate::new(192000).unwrap()),
        max_bit_depth: Some(BitDepth::Bits32),
        max_channels: Some(ChannelConfig::Stereo),
        power: PowerCapabilities {
            max_power_ma: 500,
            self_powered: false,
        },
        controls: ControlCapabilities {
            has_volume: true,
            has_mute: true,
            has_bass: false,
            has_treble: false,
            has_eq: false,
        },
        feature_units: vec![],
        input_terminals: vec![],
        output_terminals: vec![],
    };
    
    let requirements = AudioRequirements::new();
    let devices = vec![device1, device2];
    let result = DeviceMatchingLogic::find_best_match(&devices, &requirements);
    
    assert!(result.is_some());
    let best = result.unwrap();
    assert_eq!(best.max_sample_rate.unwrap().hz(), 192000);
    assert_eq!(best.max_bit_depth.unwrap().bits(), 32);
}
