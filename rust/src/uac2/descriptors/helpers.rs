use crate::uac2::error::Uac2Error;

pub fn require_len(data: &[u8], min: usize) -> Result<(), Uac2Error> {
    if data.len() < min {
        return Err(Uac2Error::InvalidDescriptor(format!(
            "expected at least {} bytes, got {}",
            min,
            data.len()
        )));
    }
    Ok(())
}

pub fn read_u16_le(data: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([data[offset], data[offset + 1]])
}

pub fn read_u32_le(data: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
    ])
}
