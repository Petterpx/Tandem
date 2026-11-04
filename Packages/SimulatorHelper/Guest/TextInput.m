// A session-owned simulator process. It talks to the focused app through AXRuntime;
// it never loads code into that app or changes its keyboard/language preferences.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

@protocol TandemAXElement <NSObject>
+ (id<TandemAXElement>)primaryApp;
- (id<TandemAXElement>)firstResponderForFocus;
- (BOOL)hasTextEntry;
- (uint64_t)traits;
- (id)value;
- (NSRange)selectedTextRange;
- (void)insertText:(NSString *)text asUndoableAction:(BOOL)undoable;
@end

static volatile sig_atomic_t stopping;
static void stop(int number) { stopping = 1; close(STDIN_FILENO); }
static void sendJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}
static NSDictionary *failure(id identifier, NSString *code, NSString *message) {
    return @{ @"id": identifier ?: @0, @"ok": @NO, @"code": code, @"error": message };
}

int main(void) {
    @autoreleasepool {
        signal(SIGTERM, stop);
        signal(SIGINT, stop);
        signal(SIGPIPE, stop);
        void *runtime = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        Class<TandemAXElement> elementClass = (Class<TandemAXElement>)NSClassFromString(@"AXElement");
        BOOL (*enabled)(void) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");
        void (*setEnabled)(BOOL) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
        if (!runtime || !elementClass || !enabled || !setEnabled ||
            ![(Class)elementClass instancesRespondToSelector:@selector(insertText:asUndoableAction:)]) {
            sendJSON(failure(nil, @"UNSUPPORTED", @"The simulator runtime does not provide native text insertion"));
            return 1;
        }
        BOOL changedAccessibility = !enabled();
        if (changedAccessibility) setEnabled(YES);
        @try {
            // One read-only preheat of the currently focused app. There is no polling
            // and no change to the foreground app, keyboard, caret, or selection.
            (void)[[[elementClass primaryApp] firstResponderForFocus] hasTextEntry];
            sendJSON(@{ @"event": @"ready", @"accessibilityChanged": @(changedAccessibility), @"pid": @(getpid()) });
            char *line = NULL;
            size_t capacity = 0;
            while (!stopping && getline(&line, &capacity, stdin) >= 0) {
                @autoreleasepool {
                    id decoded = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    NSDictionary *request = [decoded isKindOfClass:NSDictionary.class] ? decoded : @{};
                    id identifier = [request isKindOfClass:NSDictionary.class] ? request[@"id"] : nil;
                    NSString *command = request[@"command"];
                    NSString *text = request[@"text"];
                    if (![command isKindOfClass:NSString.class]) {
                        sendJSON(failure(identifier, @"INVALID_ARGUMENT", @"Malformed native text request"));
                        continue;
                    }
                    if ([command isEqualToString:@"quit"]) {
                        sendJSON(@{ @"id": identifier ?: @0, @"ok": @YES });
                        break;
                    }
                    if (![text isKindOfClass:NSString.class]) {
                        sendJSON(failure(identifier, @"INVALID_ARGUMENT", @"text is required"));
                        continue;
                    }
                    if (![command isEqualToString:@"text"]) {
                        sendJSON(failure(identifier, @"UNSUPPORTED", @"Unsupported native text command"));
                        continue;
                    }
                    if ([command isEqualToString:@"text"]) {
                        id<TandemAXElement> app = [elementClass primaryApp];
                        id<TandemAXElement> editor = [app firstResponderForFocus];
                        if (!editor || ![editor hasTextEntry]) {
                            sendJSON(failure(identifier, @"UNSUPPORTED", @"Focus an editable text field before typing"));
                            continue;
                        }
                        // AXRuntime intentionally refuses insertion into secure controls. Detect it
                        // before sending any edit so the host can safely use system Paste.
                        if (([editor traits] & (UINT64_C(1) << 24)) != 0) {
                            sendJSON(failure(identifier, @"NATIVE_PASTE_REQUIRED", @"Secure fields require system Paste; no text was inserted"));
                            continue;
                        }
                        if (text.length > 0) {
                            // AX's insertion operation uses the live caret/selection and commits literal
                            // Unicode independently of the active hardware/software keyboard layout.
                            // Never retry this operation: a failed response can follow a successful edit.
                            NSRange before = [editor selectedTextRange];
                            [editor insertText:text asUndoableAction:YES];
                            NSRange after = [editor selectedTextRange];
                            if (before.location == NSNotFound || after.location != before.location + text.length || after.length != 0) {
                                sendJSON(failure(identifier, @"UNSUPPORTED", @"Native text was sent but its caret update could not be confirmed; verify the field before retrying"));
                                continue;
                            }
                        }
                    }
                    sendJSON(@{ @"id": identifier ?: @0, @"ok": @YES });
                }
            }
            free(line);
        } @catch (NSException *exception) {
            // Do not include exception descriptions: UIKit may include user-entered text.
            sendJSON(failure(nil, @"CONNECTION_FAILED", @"Native text delivery was interrupted; verify the field before retrying"));
        } @finally {
            if (changedAccessibility) setEnabled(NO);
        }
    }
    return 0;
}
