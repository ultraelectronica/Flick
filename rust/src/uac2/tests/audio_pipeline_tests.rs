use crate::uac2::audio_format::{AudioFormat, BitDepth, ChannelConfig, FormatType, SampleRate};
use crate::uac2::audio_pipeline::{AudioPipeline, BitDepthConverter, FormatConverter, PassthroughConverter};

#[test]
fn test_passthrough_converter() {
    let converter = PassthroughConverter;
    let input = vec![1u8, 2, 3, 4, 5];
    let mut output = vec![0u8; 5];
    
    let converted = converter.convert(&input, &mut output).unwrap();
    assert_eq!(converted, 5);
    assert_eq!(output, input);
}

#[test]
fn test_passthrough_output_size() {
    let converter = PassthroughConverter;
    assert_eq!(converter.output_size(100), 100);
    assert_eq!(converter.output_size(1024), 1024);
}

#[test]
fn test_bit_depth_converter_16_to_24() {
    let converter = BitDepthConverter::new(BitDepth::Bits16, BitDepth::Bits24);
    
    let input = vec![0x00, 0x10, 0x00, 0x20];
    let mut output = vec![0u8; 6];
    
    let converted = converter.convert(&input, &mut output).unwrap();
    assert_eq!(converted, 6);
}

#[test]
fn test_bit_depth_converter_24_to_16() {
    let converter = BitDepthConverter::new(BitDepth::Bits24, BitDepth::Bits16);
    
    let input = vec![0x00, 0x10, 0x20, 0x00, 0x30, 0x40];
    let mut output = vec![0u8; 4];
    
    let converted = converter.convert(&input, &mut output).unwrap();
    assert_eq!(converted, 4);
}

#[test]
fn test_bit_depth_converter_same_depth() {
    let converter = BitDepthConverter::new(BitDepth::Bits16, BitDepth::Bits16);
    
    let input = vec![0x00, 0x10, 0x00, 0x20];
    let mut output = vec![0u8; 4];
    
    let converted = converter.convert(&input, &mut output).unwrap();
    assert_eq!(converted, 4);
    assert_eq!(output, input);
}

#[test]
fn test_bit_depth_converter_output_size() {
    let converter_16_24 = BitDepthConverter::new(BitDepth::Bits16, BitDepth::Bits24);
    assert_eq!(converter_16_24.output_size(4), 6);
    
    let converter_24_16 = BitDepthConverter::new(BitDepth::Bits24, BitDepth::Bits16);
    assert_eq!(converter_24_16.output_size(6), 4);
}

#[test]
fn test_audio_pipeline_bit_perfect() {
    let format = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let pipeline = AudioPipeline::new(format.clone(), format, 4096).unwrap();
    assert!(pipeline.is_passthrough());
}

#[test]
fn test_audio_pipeline_with_conversion() {
    let source = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let target = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits24,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let pipeline = AudioPipeline::new(source, target, 4096).unwrap();
    assert!(!pipeline.is_passthrough());
}

#[test]
fn test_audio_pipeline_process() {
    let format = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let pipeline = AudioPipeline::new(format.clone(), format, 4096).unwrap();
    
    let input = vec![1u8; 100];
    let processed = pipeline.process(&input).unwrap();
    assert_eq!(processed, 100);
    assert_eq!(pipeline.available(), 100);
}

#[test]
fn test_audio_pipeline_read() {
    let format = AudioFormat::new(
        vec![SampleRate::new(44100).unwrap()],
        BitDepth::Bits16,
        ChannelConfig::Stereo,
        FormatType::Pcm,
    ).unwrap();
    
    let pipeline = AudioPipeline::new(format.clone(), format, 4096).unwrap();
    
    let input = vec![1u8; 100];
    pipeline.process(&input).unwrap();
    
    let mut output = vec![0u8; 100];
    let read = pipeline.read(&mut output).unwrap();
    assert_eq!(read, 100);
    assert_eq!(output, input);
}
