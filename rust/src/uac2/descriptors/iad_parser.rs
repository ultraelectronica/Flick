use super::constants::USB_DT_INTERFACE_ASSOCIATION;
use super::helpers::require_len;
use super::types::Iad;
use super::validation::validate_iad;
use crate::uac2::error::Uac2Error;

pub fn parse_iad_internal(data: &[u8]) -> Result<Iad, Uac2Error> {
    const IAD_LEN: usize = 8;
    require_len(data, IAD_LEN)?;
    if data[1] != USB_DT_INTERFACE_ASSOCIATION {
        return Err(Uac2Error::InvalidDescriptor("not an IAD".to_string()));
    }
    let iad = Iad {
        b_first_interface: data[2],
        b_interface_count: data[3],
        b_function_class: data[4],
        b_function_sub_class: data[5],
        b_function_protocol: data[6],
        i_function: data[7],
    };
    validate_iad(&iad)?;
    Ok(iad)
}
