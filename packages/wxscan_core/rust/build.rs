//! Points the linker at the TFLite C library.
//!
//! `hook/build.dart` downloads that library and passes its location and link
//! name here, because the distributions do not agree on a name (Android's is
//! LiteRt) and iOS ships a static framework that is linked in rather than
//! loaded beside us. This crate has one consumer, that hook: the camera plugin
//! shares the library it produces instead of building its own.
fn main() {
    for var in ["TFLITE_LIB_DIR", "TFLITE_LIB_NAME", "TFLITE_LINK_STATIC"] {
        println!("cargo:rerun-if-env-changed={var}");
    }

    let Ok(dir) = std::env::var("TFLITE_LIB_DIR") else {
        // Built on its own, by `cargo build` in this directory. The link step
        // reports the missing library, which is a clearer error than this one.
        return;
    };
    let name = std::env::var("TFLITE_LIB_NAME").unwrap_or_else(|_| "tensorflowlite_c".into());
    let static_link = std::env::var("TFLITE_LINK_STATIC").as_deref() == Ok("1");

    println!("cargo:rustc-link-search=native={dir}");
    if static_link {
        // Linking TFLite in means bringing everything it was built against:
        // it is C++ internally, calls the accelerate routines, and its iOS
        // build reaches into the Objective-C runtime and Foundation.
        println!("cargo:rustc-link-lib=static={name}");
        println!("cargo:rustc-link-lib=c++");
        println!("cargo:rustc-link-lib=objc");
        for framework in ["Accelerate", "Foundation", "CoreFoundation", "Metal", "CoreML"] {
            println!("cargo:rustc-link-arg=-framework");
            println!("cargo:rustc-link-arg={framework}");
        }
    } else {
        println!("cargo:rustc-link-lib=dylib={name}");
    }
}
