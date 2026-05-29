use std::ffi::CStr;
use std::os::raw::c_char;
use tokenizers::Tokenizer;

pub struct TokenizerHandle {
    pub tokenizer: Tokenizer,
}

#[no_mangle]
pub extern "C" fn hf_tokenizer_from_file(path: *const c_char) -> *mut TokenizerHandle {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let c_str = unsafe { CStr::from_ptr(path) };
    let path_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    match Tokenizer::from_file(path_str) {
        Ok(tok) => Box::into_raw(Box::new(TokenizerHandle { tokenizer: tok })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn hf_tokenizer_encode(
    handle: *mut TokenizerHandle,
    text: *const c_char,
    add_special_tokens: bool,
    out_ids: *mut u32,
    out_ids_len: *mut i32,
    out_mask: *mut u32,
    out_mask_len: *mut i32,
) -> i32 {
    if handle.is_null() || text.is_null()
        || out_ids.is_null() || out_ids_len.is_null()
        || out_mask.is_null() || out_mask_len.is_null() {
        return -1;
    }
    let handle_ref = unsafe { &mut *handle };
    let text_str = match unsafe { CStr::from_ptr(text) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let encoding = match handle_ref.tokenizer.encode(text_str, add_special_tokens) {
        Ok(enc) => enc,
        Err(_) => return -1,
    };
    let ids = encoding.get_ids();
    let mask = encoding.get_attention_mask();
    unsafe {
        *out_ids_len = ids.len() as i32;
        *out_mask_len = mask.len() as i32;
        if !ids.is_empty() {
            std::ptr::copy_nonoverlapping(ids.as_ptr(), out_ids, ids.len());
        }
        if !mask.is_empty() {
            std::ptr::copy_nonoverlapping(mask.as_ptr(), out_mask, mask.len());
        }
    }
    0
}

#[no_mangle]
pub extern "C" fn hf_tokenizer_free(handle: *mut TokenizerHandle) {
    if !handle.is_null() {
        unsafe { let _ = Box::from_raw(handle); }
    }
}
