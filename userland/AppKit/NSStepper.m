/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSStepper: an NSControl over an NSStepperCell; the up and down arrow keys step it. */
#import "NSControl_Finch.h"

@interface NSStepperCell (FinchStepper)
- (void)_finchStep:(int)direction;
@end

@implementation NSStepper

+ (Class)cellClass
{
    return [super cellClass] ?: [NSStepperCell class];
}

static NSStepperCell *
cell_of(NSStepper *s)
{
    id c = [s cell];
    return [c isKindOfClass:[NSStepperCell class]] ? c : nil;
}

- (double)minValue { return [cell_of(self) minValue]; }
- (void)setMinValue:(double)v { [cell_of(self) setMinValue:v]; }
- (double)maxValue { return [cell_of(self) maxValue]; }
- (void)setMaxValue:(double)v { [cell_of(self) setMaxValue:v]; }
- (double)increment { return [cell_of(self) increment]; }
- (void)setIncrement:(double)v { [cell_of(self) setIncrement:v]; }
- (BOOL)valueWraps { return [cell_of(self) valueWraps]; }
- (void)setValueWraps:(BOOL)flag { [cell_of(self) setValueWraps:flag]; }
- (BOOL)autorepeat { return [cell_of(self) autorepeat]; }
- (void)setAutorepeat:(BOOL)flag { [cell_of(self) setAutorepeat:flag]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)_finchBecomesFirstResponderOnClick { return NO; }

- (void)keyDown:(NSEvent *)event
{
    [self interpretKeyEvents:@[ event ]];
}

- (void)_finchKeyStep:(int)direction
{
    NSStepperCell *c = cell_of(self);
    if (!c || ![self isEnabled])
        return;
    [c _finchStep:direction];
    [self setNeedsDisplay:YES];
    [self sendAction:[self action] to:[self target]];
}

- (void)moveUp:(id)sender { [self _finchKeyStep:1]; }
- (void)moveDown:(id)sender { [self _finchKeyStep:-1]; }

@end
