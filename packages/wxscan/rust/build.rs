//! Points the linker at the TFLite C library.
//!
//! `hook/build.dart` downloads that library and passes its location and link
//! name here, because iOS builds a static archive that is linked in rather
//! than loaded beside us. This crate has one consumer, that hook: the camera
//! plugin shares the library it produces instead of building its own.
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

        // ELF records the dependency by name and searches for it at load time,
        // and the Dart tooling's answer to that - both libraries copied into
        // one directory - only helps if this one is told to look beside
        // itself. Without it a Linux build links, and then dlopen fails with
        // `libtensorflowlite_c.so: cannot open shared object file`.
        //
        // Not needed elsewhere: Mach-O carries an install name the tooling
        // rewrites, Windows searches the loading module's directory, and an
        // Android package puts every library in one directory the loader
        // already knows.
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
            println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
        }
    }
}
