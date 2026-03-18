use crate::uac2::error::Uac2Error;

pub trait DescriptorParser {
    type Output;
    fn parse(&self, data: &[u8]) -> Result<Self::Output, Uac2Error>;
}
