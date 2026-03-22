use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, FormatType, SampleRate};

#[test]
fn test_sample_rate_creation() {
    assert!(SampleRate::new(44100).is_ok());
    assert!(SampleRate::new(48000).is_ok());
    assert!(SampleRate::new(96000).is_ok());
    assert!(SampleRate::new(192000).is_ok());
    assert!(SampleRate::new(0).is_err());
}

#[test]
fn test_sample_rate_hz() {
    let rate = SampleRate::new(48000).unwrap();
    assert_eq!(rate.hz(), 48000);
}

#[test]
fn test_bit_depth_creation() {
    assert!(BitDepth::from_bits(16).is_ok());
    assert!(BitDepth::from_bits(24).is_ok());
    assert!(BitDepth::from_bits(32).is_ok());
    assert!(BitDepth::from_bits(8).is_err());
    assert!(BitDepth::from_bits(48).is_err());
}

#[test]
fn test_bit_depth_bits() {
    assert_eq!(BitDepth::Bits16.bits(), 16);
    assert_eq!(BitDepth::Bits24.bits(), 24);
    assert_eq!(BitDepth::Bits32.bits(), 32);
}

#[test]
fn test_channel_config_creation() {
    assert!(ChannelConfig::from_count(1).is_ok());
    assert!(ChannelConfig::from_count(2).is_ok());
    assert!(ChannelConfig::from_count(6).is_ok());
    assert!(ChannelConfig::from_count(8).is_ok());
    assert!(ChannelConfig::from_count(0).is_err());
}

#[test]
fn test_channel_config_count() {
    assert_eq!(ChannelConfig::Mono.count(), 1);
    assert_eq!(ChannelConfig::Stereo.count(), 2);
    assert_eq!(ChannelConfig::MultiChannel(6).count(), 6);
    assert_eq!(ChannelConfig::MultiChannel(8).count(), 8);
}

#[test]
fn test_audio_format_creation() {
    let format = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    );
    
    assert!(format.is_ok());
    let format = format.unwrap();
    assert_eq!(format.format_type, FormatType::Pcm);
    assert_eq!(format.bit_depth, BitDepth::Bits16);
    assert_eq!(format.channels, ChannelConfig::Stereo);
    assert_eq!(format.sample_rates.len(), 1);
}

#[test]
fn test_audio_format_empty_sample_rates() {
    let format = AudioFormat::new(
        vec![],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    );
    
    assert!(format.is_err());
}

#[test]
fn test_audio_format_supports_sample_rate() {
    let format = AudioFormat::new(
        vec![
            SampleRate::new(44100).unwrap(),
            SampleRate::new(48000).unwrap(),
        ],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    assert!(format.supports_sample_rate(SampleRate::new(44100).unwrap()));
    assert!(format.supports_sample_rate(SampleRate::new(48000).unwrap()));
    assert!(!format.supports_sample_rate(SampleRate::new(96000).unwrap()));
}

#[test]
fn test_format_type_variants() {
    assert_eq!(FormatType::Pcm.tag(), FormatType::Pcm.tag());
    assert_ne!(FormatType::Pcm.tag(), FormatType::IeeFloat.tag());
}
