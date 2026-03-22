use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, FormatType, SampleRate};
use crate::uac2::capabilities::{FormatMatcher, DeviceType};

#[test]
fn test_format_matcher_find_optimal_exact_match() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(48000).unwrap()],
            BitDepth::Bits24,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let result = FormatMatcher::find_optimal_format(
        &formats,
        Some(SampleRate::new(48000).unwrap()),
        Some(BitDepth::Bits24),
    );
    
    assert!(result.is_some());
    let format = result.unwrap();
    assert_eq!(format.bit_depth, BitDepth::Bits24);
    assert!(format.supports_sample_rate(SampleRate::new(48000).unwrap()));
}

#[test]
fn test_format_matcher_find_optimal_no_match() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let result = FormatMatcher::find_optimal_format(
        &formats,
        Some(SampleRate::new(96000).unwrap()),
        None,
    );
    
    assert!(result.is_some());
}

#[test]
fn test_format_matcher_find_optimal_empty() {
    let formats = vec![];
    
    let result = FormatMatcher::find_optimal_format(
        &formats,
        Some(SampleRate::new(48000).unwrap()),
        Some(BitDepth::Bits24),
    );
    
    assert!(result.is_none());
}

#[test]
fn test_format_matcher_find_optimal_highest_quality() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(96000).unwrap()],
            BitDepth::Bits24,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(192000).unwrap()],
            BitDepth::Bits32,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let result = FormatMatcher::find_optimal_format(&formats, None, None);
    
    assert!(result.is_some());
    let format = result.unwrap();
    assert_eq!(format.bit_depth, BitDepth::Bits32);
}

#[test]
fn test_format_matcher_find_compatible_formats() {
    let source = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits24,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(48000).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let compatible = FormatMatcher::find_compatible_formats(&formats, &source);
    assert_eq!(compatible.len(), 2);
}

#[test]
fn test_format_matcher_find_compatible_formats_none() {
    let source = AudioFormat::new(
        vec![SampleRate::new(192000).unwrap()],
        BitDepth::Bits32,
        ChannelConfig::MultiChannel(8),
        FormatType::Pcm,
    ).unwrap();
    
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(44100).unwrap()],
            BitDepth::Bits16,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let compatible = FormatMatcher::find_compatible_formats(&formats, &source);
    assert_eq!(compatible.len(), 0);
}

#[test]
fn test_device_type_variants() {
    assert_ne!(DeviceType::DacOnly, DeviceType::AmpOnly);
    assert_ne!(DeviceType::DacOnly, DeviceType::DacAmpCombo);
    assert_ne!(DeviceType::DacOnly, DeviceType::Unknown);
}

#[test]
fn test_format_matcher_prefers_pcm() {
    let formats = vec![
        AudioFormat::new(
            vec![SampleRate::new(48000).unwrap()],
            BitDepth::Bits32,
            ChannelConfig::Stereo,
            FormatType::IeeFloat,
        ).unwrap(),
        AudioFormat::new(
            vec![SampleRate::new(48000).unwrap()],
            BitDepth::Bits32,
            ChannelConfig::Stereo,
            FormatType::Pcm,
        ).unwrap(),
    ];
    
    let result = FormatMatcher::find_optimal_format(&formats, None, None);
    assert!(result.is_some());
    let format = result.unwrap();
    assert_eq!(format.format_type, FormatType::Pcm);
}
