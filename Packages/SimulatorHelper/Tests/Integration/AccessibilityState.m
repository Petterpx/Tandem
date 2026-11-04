// Test-only observer used to prove guest process lifecycle restores its AX setting.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
    BOOL (*get)(void) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");
    void (*set)(BOOL) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    if (!get || !set) return 1;
    if (argc > 1) set(atoi(argv[1]) != 0);
    printf("%d\n", get());
    return 0;
}
