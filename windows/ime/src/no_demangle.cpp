// no_demangle.cpp — size (llvm-mingw builds only; not compiled with MSVC).
//
// The static libc++abi's default terminate handler names an uncaught exception's type with
// __cxa_demangle, which drags the whole Itanium demangler (~128 KB of x64 code) into every
// binary that links any libc++ code able to throw — the TIP loaded into every process
// included. VietTelex is built -fno-exceptions and never throws; the only caller is that
// terminate message. Defining the symbol here keeps the archive member out: the message
// would print the mangled name instead.
#include <cstddef>

extern "C" char* __cxa_demangle(const char*, char*, size_t*, int* status) {
    if (status) *status = -2;  // "not a valid mangled name": callers fall back to the raw name
    return nullptr;
}
