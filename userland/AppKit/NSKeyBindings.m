/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Key bindings: -interpretKeyEvents: turns a key down into -insertText: or
 * -doCommandBySelector: of text-editing actions.
 *
 * The bindings are written as in the documented key-binding dictionaries
 * (~/Library/KeyBindings/DefaultKeyBinding.dict): a key, prefixed by ^
 * (control), ~ (option), $ (shift) and @ (command), bound to one action or
 * several. Finch's table states the standard Cocoa bindings; a user's
 * DefaultKeyBinding.dict is read on top of it, as on macOS. A key with no
 * binding for its modifiers is tried without shift; failing that, a key with
 * control or command, or a function key, does nothing (noop:), and anything
 * else inserts its characters.
 */
#import "AppKit_Finch.h"

/* Keys: a character, or \uF7xx for the function keys (NSUpArrowFunctionKey ...). */
static const char *const standard[][2] = {
    {"\x03", "insertNewline:"}, {"\x08", "deleteBackward:"}, {"\t", "insertTab:"}, {"\n", "insertNewline:"},
    {"\r", "insertNewline:"}, {"\x19", "insertBacktab:"}, {"\x1b", "cancelOperation:"}, {"\x7f", "deleteBackward:"},
    {"\\UF700", "moveUp:"}, {"\\UF701", "moveDown:"}, {"\\UF702", "moveLeft:"}, {"\\UF703", "moveRight:"},
    {"\\UF708", "complete:"}, {"\\UF728", "deleteForward:"}, {"\\UF729", "scrollToBeginningOfDocument:"},
    {"\\UF72B", "scrollToEndOfDocument:"}, {"\\UF72C", "scrollPageUp:"}, {"\\UF72D", "scrollPageDown:"},
    {"\\UF739", "delete:"},
    /* shift */
    {"$\\UF700", "moveUpAndModifySelection:"}, {"$\\UF701", "moveDownAndModifySelection:"},
    {"$\\UF702", "moveLeftAndModifySelection:"}, {"$\\UF703", "moveRightAndModifySelection:"},
    {"$\\UF729", "moveToBeginningOfDocumentAndModifySelection:"},
    {"$\\UF72B", "moveToEndOfDocumentAndModifySelection:"}, {"$\\UF72C", "pageUpAndModifySelection:"},
    {"$\\UF72D", "pageDownAndModifySelection:"},
    /* command */
    {"@.", "cancelOperation:"}, {"@ ", "cycleToNextInputScript:"}, {"@\x7f", "deleteToBeginningOfLine:"},
    {"@\\UF700", "moveToBeginningOfDocument:"}, {"@\\UF701", "moveToEndOfDocument:"},
    {"@\\UF702", "moveToLeftEndOfLine:"}, {"@\\UF703", "moveToRightEndOfLine:"},
    {"@$\\UF700", "moveToBeginningOfDocumentAndModifySelection:"},
    {"@$\\UF701", "moveToEndOfDocumentAndModifySelection:"},
    {"@$\\UF702", "moveToLeftEndOfLineAndModifySelection:"},
    {"@$\\UF703", "moveToRightEndOfLineAndModifySelection:"},
    {"@^ ", "togglePlatformInputSystem:"}, {"@^\\UF701", "makeBaseWritingDirectionNatural:"},
    {"@^\\UF702", "makeBaseWritingDirectionRightToLeft:"}, {"@^\\UF703", "makeBaseWritingDirectionLeftToRight:"},
    {"@~ ", "cycleToNextInputKeyboardLayout:"}, {"@~^\\UF701", "makeTextWritingDirectionNatural:"},
    {"@~^\\UF702", "makeTextWritingDirectionRightToLeft:"}, {"@~^\\UF703", "makeTextWritingDirectionLeftToRight:"},
    /* control: the Emacs keys */
    {"^\"", "insertDoubleQuoteIgnoringSubstitution:"}, {"^'", "insertSingleQuoteIgnoringSubstitution:"},
    {"^/", "insertRightToLeftSlash:"}, {"^a", "moveToBeginningOfParagraph:"}, {"^b", "moveBackward:"},
    {"^d", "deleteForward:"}, {"^e", "moveToEndOfParagraph:"}, {"^f", "moveForward:"}, {"^h", "deleteBackward:"},
    {"^k", "deleteToEndOfParagraph:"}, {"^l", "centerSelectionInVisibleArea:"}, {"^n", "moveDown:"},
    {"^o", "insertNewlineIgnoringFieldEditor:,moveBackward:"}, {"^p", "moveUp:"}, {"^t", "transpose:"},
    {"^v", "pageDown:"}, {"^y", "yank:"}, {"^A", "moveToBeginningOfParagraphAndModifySelection:"},
    {"^B", "moveBackwardAndModifySelection:"}, {"^E", "moveToEndOfParagraphAndModifySelection:"},
    {"^F", "moveForwardAndModifySelection:"}, {"^N", "moveDownAndModifySelection:"},
    {"^P", "moveUpAndModifySelection:"}, {"^V", "pageDownAndModifySelection:"}, {"^\x03", "insertLineBreak:"},
    {"^\t", "selectNextKeyView:"}, {"^\n", "insertLineBreak:"}, {"^\r", "insertLineBreak:"},
    {"^\x19", "selectPreviousKeyView:"}, {"^\x7f", "deleteBackwardByDecomposingPreviousCharacter:"},
    {"^\\UF700", "scrollPageUp:"}, {"^\\UF701", "scrollPageDown:"}, {"^\\UF702", "moveToLeftEndOfLine:"},
    {"^\\UF703", "moveToRightEndOfLine:"}, {"^$\\UF702", "moveToLeftEndOfLineAndModifySelection:"},
    {"^$\\UF703", "moveToRightEndOfLineAndModifySelection:"},
    /* option */
    {"~\x03", "insertNewlineIgnoringFieldEditor:"}, {"~\x08", "deleteWordBackward:"},
    {"~\t", "insertTabIgnoringFieldEditor:"}, {"~\n", "insertNewlineIgnoringFieldEditor:"},
    {"~\r", "insertNewlineIgnoringFieldEditor:"}, {"~\x1b", "complete:"}, {"~\x7f", "deleteWordBackward:"},
    {"~\\UF700", "moveBackward:,moveToBeginningOfParagraph:"}, {"~\\UF701", "moveForward:,moveToEndOfParagraph:"},
    {"~\\UF702", "moveWordLeft:"}, {"~\\UF703", "moveWordRight:"}, {"~\\UF728", "deleteWordForward:"},
    {"~\\UF72C", "pageUp:"}, {"~\\UF72D", "pageDown:"},
    {"~$\\UF700", "moveParagraphBackwardAndModifySelection:"},
    {"~$\\UF701", "moveParagraphForwardAndModifySelection:"}, {"~$\\UF702", "moveWordLeftAndModifySelection:"},
    {"~$\\UF703", "moveWordRightAndModifySelection:"}, {"~^b", "moveWordBackward:"}, {"~^f", "moveWordForward:"},
    {"~^B", "moveWordBackwardAndModifySelection:"}, {"~^F", "moveWordForwardAndModifySelection:"},
    {"~^\x7f", "deleteWordBackward:"},
};

/* A binding's key as the dictionaries spell it: modifier prefixes, then the key. */
static NSString *
spell(unichar key, NSEventModifierFlags mods)
{
    NSMutableString *s = [NSMutableString string];
    if (mods & NSEventModifierFlagCommand)
        [s appendString:@"@"];
    if (mods & NSEventModifierFlagOption)
        [s appendString:@"~"];
    if (mods & NSEventModifierFlagControl)
        [s appendString:@"^"];
    if (mods & NSEventModifierFlagShift)
        [s appendString:@"$"];
    [s appendString:[NSString stringWithCharacters:&key length:1]];
    return s;
}

/* "^~$@" prefixes in any order, then the key; normalised to spell()'s order. */
static NSString *
normalise(NSString *spec)
{
    NSEventModifierFlags mods = 0;
    NSUInteger i = 0, n = [spec length];
    for (; i + 1 < n; i++) {
        unichar c = [spec characterAtIndex:i];
        if (c == '^')
            mods |= NSEventModifierFlagControl;
        else if (c == '~')
            mods |= NSEventModifierFlagOption;
        else if (c == '$')
            mods |= NSEventModifierFlagShift;
        else if (c == '@')
            mods |= NSEventModifierFlagCommand;
        else
            break;
    }
    if (i >= n)
        return nil;
    NSString *rest = [spec substringFromIndex:i];
    unichar key;
    if ([rest length] == 6 && [rest hasPrefix:@"\\U"]) {
        unsigned v = 0;
        [[NSScanner scannerWithString:[rest substringFromIndex:2]] scanHexInt:&v];
        key = (unichar)v;
    } else if ([rest length] == 1) {
        key = [rest characterAtIndex:0];
    } else {
        return nil;
    }
    return spell(key, mods);
}

static NSDictionary *
table(void)
{
    static NSMutableDictionary *t;
    if (t)
        return t;
    t = [[NSMutableDictionary alloc] init];
    for (size_t i = 0; i < sizeof standard / sizeof *standard; i++) {
        NSString *k = normalise([NSString stringWithUTF8String:standard[i][0]]);
        if (k)
            t[k] = [[NSString stringWithUTF8String:standard[i][1]] componentsSeparatedByString:@","];
    }
    /* The user's bindings, as macOS reads them. */
    NSString *user = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/KeyBindings/DefaultKeyBinding.dict"];
    NSDictionary *mine = [NSDictionary dictionaryWithContentsOfFile:user];
    for (NSString *spec in mine) {
        NSString *k = normalise(spec);
        id v = mine[spec];
        if (!k)
            continue;
        if ([v isKindOfClass:[NSString class]])
            t[k] = @[ v ];
        else if ([v isKindOfClass:[NSArray class]])
            t[k] = v;
    }
    return t;
}

void
FinchInterpretKeyEvent(NSResponder *responder, NSEvent *event)
{
    if ([event type] != NSEventTypeKeyDown)
        return;
    NSEventModifierFlags mods = [event modifierFlags] & (NSEventModifierFlagShift | NSEventModifierFlagControl |
                                                         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 1) {
        unichar key = [chars characterAtIndex:0];
        /* control with a letter: the binding is spelled with the letter's case and no shift */
        NSEventModifierFlags lookup = mods;
        if ((mods & NSEventModifierFlagControl) && key < 0x80 && isalpha(key))
            lookup &= ~NSEventModifierFlagShift;
        NSArray *actions = table()[spell(key, lookup)];
        if (!actions && (lookup & NSEventModifierFlagShift))
            actions = table()[spell(key, lookup & ~NSEventModifierFlagShift)];
        if (actions) {
            for (NSString *a in actions)
                [responder doCommandBySelector:NSSelectorFromString(a)];
            return;
        }
        if (key >= 0xF700 && key <= 0xF8FF) {
            [responder doCommandBySelector:@selector(noop:)];
            return;
        }
    }
    if (mods & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) {
        [responder doCommandBySelector:@selector(noop:)];
        return;
    }
    NSString *text = [event characters];
    if ([text length])
        [responder insertText:text];
}
