/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Units and measurements (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSUnit.h> and <Foundation/NSMeasurement.h>: NSUnitConverter,
 * NSUnitConverterLinear, NSUnitConverterReciprocal (Apple's private class
 * for miles per gallon), NSUnit, NSDimension and its 22 subclasses, and
 * NSMeasurement.
 *
 * Every unit has Apple's symbol and conversion factors exactly (read from
 * Apple's Foundation), and the ICU measure unit (Apple's UAMeasureUnit) it
 * formats as, its "specifier" (NSMeasurementFormatter.m). The class
 * properties return one immortal instance each, of a runtime subclass named
 * as Apple's (_NSStatic_NSUnitLength) that codes as its superclass.
 *
 * +_measurementWithNaturalScale:system: picks the unit a value reads best
 * in, within a measurement system (0 metric, 1 UK, 2 US, 3 none), with
 * the thresholds Apple's uses; NSMeasurementFormatter's natural scale
 * option calls it.
 */
#import <Foundation/Foundation.h>
#include <os/lock.h>

#include "Foundation_Finch.h"

@interface NSUnit (FinchPrivate)
- (Class)_effectiveUnitClass;
@end

@interface NSDimension (FinchPrivate)
- (instancetype)initWithSpecifier:(NSInteger)specifier symbol:(NSString *)symbol converter:(NSUnitConverter *)converter;
- (NSInteger)specifier;
+ (NSString *)icuType;
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)measurement system:(NSInteger)system;
@end

@interface NSUnitConverterReciprocal : NSUnitConverter <NSSecureCoding> {
    double _reciprocalValue;
}
- (instancetype)initWithReciprocalValue:(double)value;
- (double)reciprocalValue;
@end

/* Doubles hash as NSNumbers do (CF's double hash), as Apple's units and
 * measurements hash them. */
static NSUInteger
hash_double(double d)
{
    return [[NSNumber numberWithDouble:d] hash];
}

/* MARK: - Immortal instances */

static id static_retain(id self, SEL _cmd) { return self; }
static void static_release(id self, SEL _cmd) { }
static NSUInteger static_retain_count(id self, SEL _cmd) { return NSUIntegerMax; }
static void static_dealloc(id self, SEL _cmd) { }
static Class static_class_for_coder(id self, SEL _cmd) { return class_getSuperclass(object_getClass(self)); }
static double static_no_constant(id self, SEL _cmd) { return 0; }

/* The _NSStatic_ subclass of `cls`, made once: retain and release do
 * nothing, and it codes and compares as `cls`. */
static Class
static_class(Class cls, const char *name)
{
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    char buf[128];
    if (!name) {
        snprintf(buf, sizeof buf, "_NSStatic_%s", class_getName(cls));
        name = buf;
    }
    Class c = objc_getClass(name);
    if (!c) {
        c = objc_allocateClassPair(cls, name, 0);
        class_addMethod(c, @selector(retain), (IMP)static_retain, "@@:");
        class_addMethod(c, @selector(release), (IMP)static_release, "v@:");
        class_addMethod(c, @selector(retainCount), (IMP)static_retain_count, "Q@:");
        class_addMethod(c, @selector(dealloc), (IMP)static_dealloc, "v@:");
        class_addMethod(c, @selector(classForCoder), (IMP)static_class_for_coder, "#@:");
        if ([cls isSubclassOfClass:[NSUnit class]] || cls == [NSUnitConverterLinear class])
            class_addMethod(c, @selector(_effectiveUnitClass), (IMP)static_class_for_coder, "#@:");
        if (strstr(name, "_NoConst")) class_addMethod(c, @selector(constant), (IMP)static_no_constant, "d@:");
        objc_registerClassPair(c);
    }
    os_unfair_lock_unlock(&lock);
    return c;
}

static NSDimension *
make_static_unit(Class cls, NSString *symbol, NSUnitConverter *converter, NSInteger specifier)
{
    NSDimension *u = [[static_class(cls, NULL) alloc] initWithSpecifier:specifier symbol:symbol converter:converter];
    [converter release];
    return u;
}

static NSUnitConverter *
make_static_linear(double coefficient, double constant)
{
    Class c = constant == 0 ? static_class([NSUnitConverterLinear class], "_NSStatic_NSStaticUnitConverterLinear_NoConst")
                            : static_class([NSUnitConverterLinear class], "_NSStatic_NSUnitConverterLinear");
    return [[c alloc] initWithCoefficient:coefficient constant:constant];
}

/* The body of a class property: the class's immortal unit. */
#define LINEAR(Class, sym, coefficient, constant, spec, icu) \
    static NSDimension *u; static dispatch_once_t once; \
    dispatch_once(&once, ^{ u = make_static_unit([Class class], sym, make_static_linear(coefficient, constant), spec); }); \
    return (id)u;
/* (Apple's reciprocal units are ordinary instances, kept forever.) */
#define RECIPROCAL(Class, sym, value, spec, icu) \
    static NSDimension *u; static dispatch_once_t once; \
    dispatch_once(&once, ^{ \
        NSUnitConverterReciprocal *c = [[NSUnitConverterReciprocal alloc] initWithReciprocalValue:value]; \
        u = [[Class alloc] initWithSpecifier:spec symbol:sym converter:c]; \
        [c release]; \
    }); \
    return (id)u;

/* MARK: - Converters */

@implementation NSUnitConverter
- (double)baseUnitValueFromValue:(double)value { return value; }
- (double)valueFromBaseUnitValue:(double)baseUnitValue { return baseUnitValue; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
@end

@implementation NSUnitConverterLinear

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoefficient:(double)coefficient { return [self initWithCoefficient:coefficient constant:0]; }

- (instancetype)initWithCoefficient:(double)coefficient constant:(double)constant
{
    if ((self = [super init])) {
        _coefficient = coefficient;
        _constant = constant;
    }
    return self;
}

- (double)coefficient { return _coefficient; }
- (double)constant { return _constant; }
- (double)baseUnitValueFromValue:(double)value { return value * _coefficient + _constant; }
- (double)valueFromBaseUnitValue:(double)baseUnitValue { return (baseUnitValue - _constant) / _coefficient; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSUnitConverterLinear class]]) return NO;
    return _coefficient == [object coefficient] && _constant == [object constant];
}

- (NSUInteger)hash { return hash_double(_coefficient) ^ hash_double(_constant); }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> coefficient = %f, constant = %f", [self class], self, _coefficient, _constant];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_coefficient forKey:@"NS.coefficient"];
    [coder encodeDouble:_constant forKey:@"NS.constant"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithCoefficient:[coder decodeDoubleForKey:@"NS.coefficient"] constant:[coder decodeDoubleForKey:@"NS.constant"]];
}

@end

@implementation NSUnitConverterReciprocal

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithReciprocalValue:(double)value
{
    if ((self = [super init])) _reciprocalValue = value;
    return self;
}

- (double)reciprocalValue { return _reciprocalValue; }
- (double)baseUnitValueFromValue:(double)value { return _reciprocalValue / value; }
- (double)valueFromBaseUnitValue:(double)baseUnitValue { return _reciprocalValue / baseUnitValue; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    return [object isKindOfClass:[NSUnitConverterReciprocal class]] && _reciprocalValue == [object reciprocalValue];
}

- (NSUInteger)hash { return hash_double(_reciprocalValue); }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> reciprocalValue = %f", [self class], self, _reciprocalValue];
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeDouble:_reciprocalValue forKey:@"NS.reciprocalValue"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithReciprocalValue:[coder decodeDoubleForKey:@"NS.reciprocalValue"]]; }

@end

/* MARK: - NSUnit, NSDimension */

@implementation NSUnit

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    [self release];
    FinchRaise(NSGenericException, "-init should never be called on NSUnit!");
}

- (instancetype)initWithSymbol:(NSString *)symbol
{
    if ((self = [super init])) _symbol = [symbol copy];
    return self;
}

- (void)dealloc
{
    [_symbol release];
    [super dealloc];
}

- (NSString *)symbol { return _symbol; }
- (Class)_effectiveUnitClass { return [self class]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSUnit class]] || [object _effectiveUnitClass] != [self _effectiveUnitClass]) return NO;
    NSString *s = [object symbol];
    return s == _symbol || [s isEqualToString:_symbol];
}

- (NSUInteger)hash { return [_symbol hash]; }

- (NSString *)description { return [NSString stringWithFormat:@"<%@: %p> %@", [self class], self, _symbol]; }

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_symbol forKey:@"NS.symbol"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithSymbol:[coder decodeObjectOfClass:[NSString class] forKey:@"NS.symbol"]];
}

@end

@implementation NSDimension {
    NSInteger _specifier;   /* the ICU measure unit, or -1 */
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)baseUnit
{
    FinchRaise(NSInvalidArgumentException, "*** You must override baseUnit in your class %s to define its base unit.", class_getName(self));
}

+ (NSString *)icuType { return nil; }
+ (BOOL)supportsRegionalPreference { return NO; }

- (instancetype)initWithSymbol:(NSString *)symbol { return [self initWithSpecifier:-1 symbol:symbol converter:nil]; }

- (instancetype)initWithSymbol:(NSString *)symbol converter:(NSUnitConverter *)converter
{
    return [self initWithSpecifier:-1 symbol:symbol converter:converter];
}

- (instancetype)initWithSpecifier:(NSInteger)specifier symbol:(NSString *)symbol converter:(NSUnitConverter *)converter
{
    if ((self = [super initWithSymbol:symbol])) {
        _converter = [converter copy];
        _specifier = specifier;
    }
    return self;
}

- (void)dealloc
{
    [_converter release];
    [super dealloc];
}

- (NSUnitConverter *)converter { return _converter; }
- (NSInteger)specifier { return _specifier; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![super isEqual:object]) return NO;
    NSUnitConverter *c = [object converter];
    return c == _converter || [c isEqual:_converter];
}

- (NSUInteger)hash { return [[self symbol] hash] ^ [_converter hash]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_converter forKey:@"NS.converter"];
    [coder encodeInteger:_specifier forKey:@"NS.specifier"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *symbol = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.symbol"];
    NSUnitConverter *converter = [coder decodeObjectOfClass:[NSUnitConverter class] forKey:@"NS.converter"];
    NSInteger specifier = [coder containsValueForKey:@"NS.specifier"] ? [coder decodeIntegerForKey:@"NS.specifier"] : -1;
    return [self initWithSpecifier:specifier symbol:symbol converter:converter];
}

/* Without a scale of its own, a dimension keeps the unit it's given. */
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    return [[[NSMeasurement alloc] initWithDoubleValue:[m doubleValue] unit:[m unit]] autorelease];
}

@end

/* MARK: - The dimensions (every unit Apple's Foundation has) */

/* Each property: symbol, then the converter (coefficient and constant, or
 * the reciprocal value), the ICU measure unit (-1: none) and, for reference,
 * the CLDR name of that unit, as Apple's private -icuSubtype gives it. */
@implementation NSUnitAcceleration
+ (NSString *)icuType { return @"acceleration"; }
+ (instancetype)baseUnit { return (id)[NSUnitAcceleration metersPerSecondSquared]; }
+ (NSUnitAcceleration *)gravity { LINEAR(NSUnitAcceleration, @"g", 9.81, 0, 0x0, "g-force") }
+ (NSUnitAcceleration *)metersPerSecondSquared { LINEAR(NSUnitAcceleration, @"m/s²", 1, 0, 0x1, "meter-per-square-second") }
@end

@implementation NSUnitAngle
+ (NSString *)icuType { return @"angle"; }
+ (instancetype)baseUnit { return (id)[NSUnitAngle degrees]; }
+ (NSUnitAngle *)arcMinutes { LINEAR(NSUnitAngle, @"ʹ", 0.016667, 0, 0x101, "arc-minute") }
+ (NSUnitAngle *)arcSeconds { LINEAR(NSUnitAngle, @"ʺ", 0.00027778, 0, 0x102, "arc-second") }
+ (NSUnitAngle *)degrees { LINEAR(NSUnitAngle, @"°", 1, 0, 0x100, "degree") }
+ (NSUnitAngle *)gradians { LINEAR(NSUnitAngle, @"grad", 0.9, 0, -1, NULL) }
+ (NSUnitAngle *)radians { LINEAR(NSUnitAngle, @"rad", 57.29577951308232, 0, 0x103, "radian") }
+ (NSUnitAngle *)revolutions { LINEAR(NSUnitAngle, @"rev", 360, 0, 0x104, "revolution") }
@end

@implementation NSUnitArea
+ (NSString *)icuType { return @"area"; }
+ (instancetype)baseUnit { return (id)[NSUnitArea squareMeters]; }
+ (NSUnitArea *)acres { LINEAR(NSUnitArea, @"ac", 4046.8564224, 0, 0x204, "acre") }
+ (NSUnitArea *)ares { LINEAR(NSUnitArea, @"a", 100, 0, -1, NULL) }
+ (NSUnitArea *)hectares { LINEAR(NSUnitArea, @"ha", 10000, 0, 0x205, "hectare") }
+ (NSUnitArea *)squareCentimeters { LINEAR(NSUnitArea, @"cm²", 0.0001, 0, 0x206, "square-centimeter") }
+ (NSUnitArea *)squareFeet { LINEAR(NSUnitArea, @"ft²", 0.09290304, 0, 0x202, "square-foot") }
+ (NSUnitArea *)squareInches { LINEAR(NSUnitArea, @"in²", 0.00064516, 0, 0x207, "square-inch") }
+ (NSUnitArea *)squareKilometers { LINEAR(NSUnitArea, @"km²", 1000000, 0, 0x201, "square-kilometer") }
+ (NSUnitArea *)squareMegameters { LINEAR(NSUnitArea, @"Mm²", 1000000000000, 0, -1, NULL) }
+ (NSUnitArea *)squareMeters { LINEAR(NSUnitArea, @"m²", 1, 0, 0x200, "square-meter") }
+ (NSUnitArea *)squareMicrometers { LINEAR(NSUnitArea, @"µm²", 1e-12, 0, -1, NULL) }
+ (NSUnitArea *)squareMiles { LINEAR(NSUnitArea, @"mi²", 2589988.110336, 0, 0x203, "square-mile") }
+ (NSUnitArea *)squareMillimeters { LINEAR(NSUnitArea, @"mm²", 1e-06, 0, -1, NULL) }
+ (NSUnitArea *)squareNanometers { LINEAR(NSUnitArea, @"nm²", 1e-18, 0, -1, NULL) }
+ (NSUnitArea *)squareYards { LINEAR(NSUnitArea, @"yd²", 0.83612736, 0, 0x208, "square-yard") }
@end

@implementation NSUnitConcentrationMass
+ (NSString *)icuType { return @"concentr"; }
+ (instancetype)baseUnit { return (id)[NSUnitConcentrationMass gramsPerLiter]; }
+ (NSUnitConcentrationMass *)gramsPerLiter { LINEAR(NSUnitConcentrationMass, @"g/L", 1, 0, -1, NULL) }
+ (NSUnitConcentrationMass *)milligramsPerDeciliter { LINEAR(NSUnitConcentrationMass, @"mg/dL", 0.01, 0, 0x1201, "milligram-per-deciliter") }
@end

@implementation NSUnitDispersion
+ (NSString *)icuType { return @"concentr"; }
+ (instancetype)baseUnit { return (id)[NSUnitDispersion partsPerMillion]; }
+ (NSUnitDispersion *)partsPerMillion { LINEAR(NSUnitDispersion, @"ppm", 1, 0, 0x1203, "permillion") }
@end

@implementation NSUnitDuration
+ (NSString *)icuType { return @"duration"; }
+ (instancetype)baseUnit { return (id)[NSUnitDuration seconds]; }
+ (NSUnitDuration *)hours { LINEAR(NSUnitDuration, @"hr", 3600, 0, 0x404, "hour") }
+ (NSUnitDuration *)microseconds { LINEAR(NSUnitDuration, @"µs", 1e-06, 0, 0x408, "microsecond") }
+ (NSUnitDuration *)milliseconds { LINEAR(NSUnitDuration, @"ms", 0.001, 0, 0x407, "millisecond") }
+ (NSUnitDuration *)minutes { LINEAR(NSUnitDuration, @"min", 60, 0, 0x405, "minute") }
+ (NSUnitDuration *)nanoseconds { LINEAR(NSUnitDuration, @"ns", 1e-09, 0, 0x409, "nanosecond") }
+ (NSUnitDuration *)picoseconds { LINEAR(NSUnitDuration, @"ps", 1e-12, 0, -1, NULL) }
+ (NSUnitDuration *)seconds { LINEAR(NSUnitDuration, @"s", 1, 0, 0x406, "second") }
@end

@implementation NSUnitElectricCharge
+ (NSString *)icuType { return @"electric"; }
+ (instancetype)baseUnit { return (id)[NSUnitElectricCharge coulombs]; }
+ (NSUnitElectricCharge *)ampereHours { LINEAR(NSUnitElectricCharge, @"Ah", 3600, 0, -1, NULL) }
+ (NSUnitElectricCharge *)coulombs { LINEAR(NSUnitElectricCharge, @"C", 1, 0, -1, NULL) }
+ (NSUnitElectricCharge *)kiloampereHours { LINEAR(NSUnitElectricCharge, @"kAh", 3600000, 0, -1, NULL) }
+ (NSUnitElectricCharge *)megaampereHours { LINEAR(NSUnitElectricCharge, @"MAh", 3600000000, 0, -1, NULL) }
+ (NSUnitElectricCharge *)microampereHours { LINEAR(NSUnitElectricCharge, @"µAh", 0.0036, 0, -1, NULL) }
+ (NSUnitElectricCharge *)milliampereHours { LINEAR(NSUnitElectricCharge, @"mAh", 3.6, 0, -1, NULL) }
@end

@implementation NSUnitElectricCurrent
+ (NSString *)icuType { return @"electric"; }
+ (instancetype)baseUnit { return (id)[NSUnitElectricCurrent amperes]; }
+ (NSUnitElectricCurrent *)amperes { LINEAR(NSUnitElectricCurrent, @"A", 1, 0, 0xf00, "ampere") }
+ (NSUnitElectricCurrent *)kiloamperes { LINEAR(NSUnitElectricCurrent, @"kA", 1000, 0, -1, NULL) }
+ (NSUnitElectricCurrent *)megaamperes { LINEAR(NSUnitElectricCurrent, @"MA", 1000000, 0, -1, NULL) }
+ (NSUnitElectricCurrent *)microamperes { LINEAR(NSUnitElectricCurrent, @"µA", 1e-06, 0, -1, NULL) }
+ (NSUnitElectricCurrent *)milliamperes { LINEAR(NSUnitElectricCurrent, @"mA", 0.001, 0, 0xf01, "milliampere") }
@end

@implementation NSUnitElectricPotentialDifference
+ (NSString *)icuType { return @"electric"; }
+ (instancetype)baseUnit { return (id)[NSUnitElectricPotentialDifference volts]; }
+ (NSUnitElectricPotentialDifference *)kilovolts { LINEAR(NSUnitElectricPotentialDifference, @"kV", 1000, 0, -1, NULL) }
+ (NSUnitElectricPotentialDifference *)megavolts { LINEAR(NSUnitElectricPotentialDifference, @"MV", 1000000, 0, -1, NULL) }
+ (NSUnitElectricPotentialDifference *)microvolts { LINEAR(NSUnitElectricPotentialDifference, @"µV", 1e-06, 0, -1, NULL) }
+ (NSUnitElectricPotentialDifference *)millivolts { LINEAR(NSUnitElectricPotentialDifference, @"mV", 0.001, 0, -1, NULL) }
+ (NSUnitElectricPotentialDifference *)volts { LINEAR(NSUnitElectricPotentialDifference, @"V", 1, 0, 0xf03, "volt") }
@end

@implementation NSUnitElectricResistance
+ (NSString *)icuType { return @"electric"; }
+ (instancetype)baseUnit { return (id)[NSUnitElectricResistance ohms]; }
+ (NSUnitElectricResistance *)kiloohms { LINEAR(NSUnitElectricResistance, @"kΩ", 1000, 0, -1, NULL) }
+ (NSUnitElectricResistance *)megaohms { LINEAR(NSUnitElectricResistance, @"MΩ", 1000000, 0, -1, NULL) }
+ (NSUnitElectricResistance *)microohms { LINEAR(NSUnitElectricResistance, @"µΩ", 1e-06, 0, -1, NULL) }
+ (NSUnitElectricResistance *)milliohms { LINEAR(NSUnitElectricResistance, @"mΩ", 0.001, 0, -1, NULL) }
+ (NSUnitElectricResistance *)ohms { LINEAR(NSUnitElectricResistance, @"Ω", 1, 0, 0xf02, "ohm") }
@end

@implementation NSUnitEnergy
+ (NSString *)icuType { return @"energy"; }
+ (instancetype)baseUnit { return (id)[NSUnitEnergy joules]; }
+ (NSUnitEnergy *)calories { LINEAR(NSUnitEnergy, @"cal", 4.184, 0, 0xc00, "calorie") }
+ (NSUnitEnergy *)foodcalories { LINEAR(NSUnitEnergy, @"C", 4184, 0, 0xc01, "foodcalorie") }
+ (NSUnitEnergy *)joules { LINEAR(NSUnitEnergy, @"J", 1, 0, 0xc02, "joule") }
+ (NSUnitEnergy *)kilocalories { LINEAR(NSUnitEnergy, @"kCal", 4184, 0, 0xc03, "kilocalorie") }
+ (NSUnitEnergy *)kilojoules { LINEAR(NSUnitEnergy, @"kJ", 1000, 0, 0xc04, "kilojoule") }
+ (NSUnitEnergy *)kilowattHours { LINEAR(NSUnitEnergy, @"kWh", 3600000, 0, 0xc05, "kilowatt-hour") }
@end

@implementation NSUnitFrequency
+ (NSString *)icuType { return @"frequency"; }
+ (instancetype)baseUnit { return (id)[NSUnitFrequency hertz]; }
+ (NSUnitFrequency *)framesPerSecond { LINEAR(NSUnitFrequency, @"fps", 1, 0, -1, NULL) }
+ (NSUnitFrequency *)gigahertz { LINEAR(NSUnitFrequency, @"GHz", 1000000000, 0, 0x1003, "gigahertz") }
+ (NSUnitFrequency *)hertz { LINEAR(NSUnitFrequency, @"Hz", 1, 0, 0x1000, "hertz") }
+ (NSUnitFrequency *)kilohertz { LINEAR(NSUnitFrequency, @"kHz", 1000, 0, 0x1001, "kilohertz") }
+ (NSUnitFrequency *)megahertz { LINEAR(NSUnitFrequency, @"MHz", 1000000, 0, 0x1002, "megahertz") }
+ (NSUnitFrequency *)microhertz { LINEAR(NSUnitFrequency, @"µHz", 1e-06, 0, -1, NULL) }
+ (NSUnitFrequency *)millihertz { LINEAR(NSUnitFrequency, @"mHz", 0.001, 0, -1, NULL) }
+ (NSUnitFrequency *)nanohertz { LINEAR(NSUnitFrequency, @"nHz", 1e-09, 0, -1, NULL) }
+ (NSUnitFrequency *)terahertz { LINEAR(NSUnitFrequency, @"THz", 1000000000000, 0, -1, NULL) }
@end

@implementation NSUnitFuelEfficiency
+ (NSString *)icuType { return @"consumption"; }
+ (instancetype)baseUnit { return (id)[NSUnitFuelEfficiency litersPer100Kilometers]; }
+ (NSUnitFuelEfficiency *)litersPer100Kilometers { LINEAR(NSUnitFuelEfficiency, @"L/100km", 1, 0, 0xd02, "liter-per-100-kilometer") }
+ (NSUnitFuelEfficiency *)milesPerGallon { RECIPROCAL(NSUnitFuelEfficiency, @"mpg", 235.215, 0xd01, NULL) }
+ (NSUnitFuelEfficiency *)milesPerImperialGallon { RECIPROCAL(NSUnitFuelEfficiency, @"mpg", 282.481, 0xd03, NULL) }
@end

@implementation NSUnitIlluminance
+ (NSString *)icuType { return @"light"; }
+ (instancetype)baseUnit { return (id)[NSUnitIlluminance lux]; }
+ (NSUnitIlluminance *)lux { LINEAR(NSUnitIlluminance, @"lx", 1, 0, 0x1100, "lux") }
@end

@implementation NSUnitInformationStorage
+ (NSString *)icuType { return @"digital"; }
+ (instancetype)baseUnit { return (id)[NSUnitInformationStorage bytes]; }
+ (NSUnitInformationStorage *)bits { LINEAR(NSUnitInformationStorage, @"bit", 0.125, 0, 0xe00, "bit") }
+ (NSUnitInformationStorage *)bytes { LINEAR(NSUnitInformationStorage, @"B", 1, 0, 0xe01, "byte") }
+ (NSUnitInformationStorage *)exabits { LINEAR(NSUnitInformationStorage, @"Eb", 1.25e+17, 0, -1, NULL) }
+ (NSUnitInformationStorage *)exabytes { LINEAR(NSUnitInformationStorage, @"EB", 1e+18, 0, -1, NULL) }
+ (NSUnitInformationStorage *)exbibits { LINEAR(NSUnitInformationStorage, @"Eib", 1.4411518807585587e+17, 0, -1, NULL) }
+ (NSUnitInformationStorage *)exbibytes { LINEAR(NSUnitInformationStorage, @"EiB", 1.152921504606847e+18, 0, -1, NULL) }
+ (NSUnitInformationStorage *)gibibits { LINEAR(NSUnitInformationStorage, @"Gib", 134217728, 0, -1, NULL) }
+ (NSUnitInformationStorage *)gibibytes { LINEAR(NSUnitInformationStorage, @"GiB", 1073741824, 0, -1, NULL) }
+ (NSUnitInformationStorage *)gigabits { LINEAR(NSUnitInformationStorage, @"Gb", 125000000, 0, 0xe02, "gigabit") }
+ (NSUnitInformationStorage *)gigabytes { LINEAR(NSUnitInformationStorage, @"GB", 1000000000, 0, 0xe03, "gigabyte") }
+ (NSUnitInformationStorage *)kibibits { LINEAR(NSUnitInformationStorage, @"Kib", 128, 0, -1, NULL) }
+ (NSUnitInformationStorage *)kibibytes { LINEAR(NSUnitInformationStorage, @"KiB", 1024, 0, -1, NULL) }
+ (NSUnitInformationStorage *)kilobits { LINEAR(NSUnitInformationStorage, @"kb", 125, 0, 0xe04, "kilobit") }
+ (NSUnitInformationStorage *)kilobytes { LINEAR(NSUnitInformationStorage, @"kB", 1000, 0, 0xe05, "kilobyte") }
+ (NSUnitInformationStorage *)mebibits { LINEAR(NSUnitInformationStorage, @"Mib", 131072, 0, -1, NULL) }
+ (NSUnitInformationStorage *)mebibytes { LINEAR(NSUnitInformationStorage, @"MiB", 1048576, 0, -1, NULL) }
+ (NSUnitInformationStorage *)megabits { LINEAR(NSUnitInformationStorage, @"Mb", 125000, 0, 0xe06, "megabit") }
+ (NSUnitInformationStorage *)megabytes { LINEAR(NSUnitInformationStorage, @"MB", 1000000, 0, 0xe07, "megabyte") }
+ (NSUnitInformationStorage *)nibbles { LINEAR(NSUnitInformationStorage, @"nibble", 0.5, 0, -1, NULL) }
+ (NSUnitInformationStorage *)pebibits { LINEAR(NSUnitInformationStorage, @"Pib", 140737488355328, 0, -1, NULL) }
+ (NSUnitInformationStorage *)pebibytes { LINEAR(NSUnitInformationStorage, @"PiB", 1125899906842624.0, 0, -1, NULL) }
+ (NSUnitInformationStorage *)petabits { LINEAR(NSUnitInformationStorage, @"Pb", 125000000000000, 0, -1, NULL) }
+ (NSUnitInformationStorage *)petabytes { LINEAR(NSUnitInformationStorage, @"PB", 1000000000000000.0, 0, 0xe0a, "petabyte") }
+ (NSUnitInformationStorage *)tebibits { LINEAR(NSUnitInformationStorage, @"Tib", 137438953472, 0, -1, NULL) }
+ (NSUnitInformationStorage *)tebibytes { LINEAR(NSUnitInformationStorage, @"TiB", 1099511627776, 0, -1, NULL) }
+ (NSUnitInformationStorage *)terabits { LINEAR(NSUnitInformationStorage, @"Tb", 125000000000, 0, 0xe08, "terabit") }
+ (NSUnitInformationStorage *)terabytes { LINEAR(NSUnitInformationStorage, @"TB", 1000000000000, 0, 0xe09, "terabyte") }
+ (NSUnitInformationStorage *)yobibits { LINEAR(NSUnitInformationStorage, @"Yib", 1.5111572745182865e+23, 0, -1, NULL) }
+ (NSUnitInformationStorage *)yobibytes { LINEAR(NSUnitInformationStorage, @"YiB", 1.2089258196146292e+24, 0, -1, NULL) }
+ (NSUnitInformationStorage *)yottabits { LINEAR(NSUnitInformationStorage, @"Yb", 1.25e+23, 0, -1, NULL) }
+ (NSUnitInformationStorage *)yottabytes { LINEAR(NSUnitInformationStorage, @"YB", 1e+24, 0, -1, NULL) }
+ (NSUnitInformationStorage *)zebibits { LINEAR(NSUnitInformationStorage, @"Zib", 1.4757395258967641e+20, 0, -1, NULL) }
+ (NSUnitInformationStorage *)zebibytes { LINEAR(NSUnitInformationStorage, @"ZiB", 1.1805916207174113e+21, 0, -1, NULL) }
+ (NSUnitInformationStorage *)zettabits { LINEAR(NSUnitInformationStorage, @"Zb", 1.25e+20, 0, -1, NULL) }
+ (NSUnitInformationStorage *)zettabytes { LINEAR(NSUnitInformationStorage, @"ZB", 1e+21, 0, -1, NULL) }
@end

@implementation NSUnitLength
+ (NSString *)icuType { return @"length"; }
+ (instancetype)baseUnit { return (id)[NSUnitLength meters]; }
+ (NSUnitLength *)astronomicalUnits { LINEAR(NSUnitLength, @"ua", 149597870700, 0, 0x510, "astronomical-unit") }
+ (NSUnitLength *)centimeters { LINEAR(NSUnitLength, @"cm", 0.01, 0, 0x501, "centimeter") }
+ (NSUnitLength *)decameters { LINEAR(NSUnitLength, @"dam", 10, 0, -1, NULL) }
+ (NSUnitLength *)decimeters { LINEAR(NSUnitLength, @"dm", 0.1, 0, 0x50a, "decimeter") }
+ (NSUnitLength *)fathoms { LINEAR(NSUnitLength, @"ftm", 1.8288, 0, 0x50e, "fathom") }
+ (NSUnitLength *)feet { LINEAR(NSUnitLength, @"ft", 0.3048, 0, 0x505, "foot") }
+ (NSUnitLength *)furlongs { LINEAR(NSUnitLength, @"fur", 201.168, 0, 0x50f, "furlong") }
+ (NSUnitLength *)hectometers { LINEAR(NSUnitLength, @"hm", 100, 0, -1, NULL) }
+ (NSUnitLength *)inches { LINEAR(NSUnitLength, @"in", 0.0254, 0, 0x506, "inch") }
+ (NSUnitLength *)kilometers { LINEAR(NSUnitLength, @"km", 1000, 0, 0x502, "kilometer") }
+ (NSUnitLength *)lightyears { LINEAR(NSUnitLength, @"ly", 9460730472580800.0, 0, 0x509, "light-year") }
+ (NSUnitLength *)megameters { LINEAR(NSUnitLength, @"Mm", 1000000, 0, -1, NULL) }
+ (NSUnitLength *)meters { LINEAR(NSUnitLength, @"m", 1, 0, 0x500, "meter") }
+ (NSUnitLength *)micrometers { LINEAR(NSUnitLength, @"µm", 1e-06, 0, 0x50b, "micrometer") }
+ (NSUnitLength *)miles { LINEAR(NSUnitLength, @"mi", 1609.344, 0, 0x507, "mile") }
+ (NSUnitLength *)millimeters { LINEAR(NSUnitLength, @"mm", 0.001, 0, 0x503, "millimeter") }
+ (NSUnitLength *)nanometers { LINEAR(NSUnitLength, @"nm", 1e-09, 0, 0x50c, "nanometer") }
+ (NSUnitLength *)nauticalMiles { LINEAR(NSUnitLength, @"NM", 1852, 0, 0x50d, "nautical-mile") }
+ (NSUnitLength *)parsecs { LINEAR(NSUnitLength, @"pc", 3.085677581491367e+16, 0, 0x511, "parsec") }
+ (NSUnitLength *)picometers { LINEAR(NSUnitLength, @"pm", 1e-12, 0, 0x504, "picometer") }
+ (NSUnitLength *)scandinavianMiles { LINEAR(NSUnitLength, @"smi", 10000, 0, 0x512, "mile-scandinavian") }
+ (NSUnitLength *)yards { LINEAR(NSUnitLength, @"yd", 0.9144, 0, 0x508, "yard") }
@end

@implementation NSUnitMass
+ (NSString *)icuType { return @"mass"; }
+ (instancetype)baseUnit { return (id)[NSUnitMass kilograms]; }
+ (NSUnitMass *)carats { LINEAR(NSUnitMass, @"ct", 0.0002, 0, 0x609, "carat") }
+ (NSUnitMass *)centigrams { LINEAR(NSUnitMass, @"cg", 1e-05, 0, -1, NULL) }
+ (NSUnitMass *)decigrams { LINEAR(NSUnitMass, @"dg", 0.0001, 0, -1, NULL) }
+ (NSUnitMass *)grams { LINEAR(NSUnitMass, @"g", 0.001, 0, 0x600, "gram") }
+ (NSUnitMass *)kilograms { LINEAR(NSUnitMass, @"kg", 1, 0, 0x601, "kilogram") }
+ (NSUnitMass *)metricTons { LINEAR(NSUnitMass, @"t", 1000, 0, 0x607, "metric-ton") }
+ (NSUnitMass *)micrograms { LINEAR(NSUnitMass, @"µg", 1e-09, 0, 0x605, "microgram") }
+ (NSUnitMass *)milligrams { LINEAR(NSUnitMass, @"mg", 1e-06, 0, 0x606, "milligram") }
+ (NSUnitMass *)nanograms { LINEAR(NSUnitMass, @"ng", 1e-12, 0, -1, NULL) }
+ (NSUnitMass *)ounces { LINEAR(NSUnitMass, @"oz", 0.0283495, 0, 0x602, "ounce") }
+ (NSUnitMass *)ouncesTroy { LINEAR(NSUnitMass, @"oz t", 0.03110348, 0, 0x60a, "ounce-troy") }
+ (NSUnitMass *)picograms { LINEAR(NSUnitMass, @"pg", 1e-15, 0, -1, NULL) }
+ (NSUnitMass *)poundsMass { LINEAR(NSUnitMass, @"lb", 0.453592, 0, 0x603, "pound") }
+ (NSUnitMass *)shortTons { LINEAR(NSUnitMass, @"ton", 907.185, 0, 0x608, "ton") }
+ (NSUnitMass *)slugs { LINEAR(NSUnitMass, @"slug", 14.5939, 0, -1, NULL) }
+ (NSUnitMass *)stones { LINEAR(NSUnitMass, @"st", 6.35029, 0, 0x604, "stone") }
@end

@implementation NSUnitPower
+ (NSString *)icuType { return @"power"; }
+ (instancetype)baseUnit { return (id)[NSUnitPower watts]; }
+ (NSUnitPower *)femtowatts { LINEAR(NSUnitPower, @"fW", 1e-15, 0, -1, NULL) }
+ (NSUnitPower *)gigawatts { LINEAR(NSUnitPower, @"GW", 1000000000, 0, 0x705, "gigawatt") }
+ (NSUnitPower *)horsepower { LINEAR(NSUnitPower, @"hp", 745.7, 0, 0x702, "horsepower") }
+ (NSUnitPower *)kilowatts { LINEAR(NSUnitPower, @"kW", 1000, 0, 0x701, "kilowatt") }
+ (NSUnitPower *)megawatts { LINEAR(NSUnitPower, @"MW", 1000000, 0, 0x704, "megawatt") }
+ (NSUnitPower *)microwatts { LINEAR(NSUnitPower, @"µW", 1e-06, 0, -1, NULL) }
+ (NSUnitPower *)milliwatts { LINEAR(NSUnitPower, @"mW", 0.001, 0, 0x703, "milliwatt") }
+ (NSUnitPower *)nanowatts { LINEAR(NSUnitPower, @"nW", 1e-09, 0, -1, NULL) }
+ (NSUnitPower *)picowatts { LINEAR(NSUnitPower, @"pW", 1e-12, 0, -1, NULL) }
+ (NSUnitPower *)terawatts { LINEAR(NSUnitPower, @"TW", 1000000000000, 0, -1, NULL) }
+ (NSUnitPower *)watts { LINEAR(NSUnitPower, @"W", 1, 0, 0x700, "watt") }
@end

@implementation NSUnitPressure
+ (NSString *)icuType { return @"pressure"; }
+ (instancetype)baseUnit { return (id)[NSUnitPressure newtonsPerMetersSquared]; }
+ (NSUnitPressure *)bars { LINEAR(NSUnitPressure, @"bar", 100000, 0, 0x809, "bar") }
+ (NSUnitPressure *)gigapascals { LINEAR(NSUnitPressure, @"GPa", 1000000000, 0, -1, NULL) }
+ (NSUnitPressure *)hectopascals { LINEAR(NSUnitPressure, @"hPa", 100, 0, 0x800, "hectopascal") }
+ (NSUnitPressure *)inchesOfMercury { LINEAR(NSUnitPressure, @"inHg", 3386.39, 0, 0x801, "inch-ofhg") }
+ (NSUnitPressure *)kilopascals { LINEAR(NSUnitPressure, @"kPa", 1000, 0, 0x806, "kilopascal") }
+ (NSUnitPressure *)megapascals { LINEAR(NSUnitPressure, @"MPa", 1000000, 0, 0x807, "megapascal") }
+ (NSUnitPressure *)millibars { LINEAR(NSUnitPressure, @"mbar", 100, 0, 0x802, "millibar") }
+ (NSUnitPressure *)millimetersOfMercury { LINEAR(NSUnitPressure, @"mmHg", 133.322, 0, 0x803, "millimeter-ofhg") }
+ (NSUnitPressure *)newtonsPerMetersSquared { LINEAR(NSUnitPressure, @"N/m²", 1, 0, -1, NULL) }
+ (NSUnitPressure *)poundsForcePerSquareInch { LINEAR(NSUnitPressure, @"psi", 6894.76, 0, 0x804, "pound-force-per-square-inch") }
@end

@implementation NSUnitSpeed
+ (NSString *)icuType { return @"speed"; }
+ (instancetype)baseUnit { return (id)[NSUnitSpeed metersPerSecond]; }
+ (NSUnitSpeed *)kilometersPerHour { LINEAR(NSUnitSpeed, @"km/h", 0.277778, 0, 0x901, "kilometer-per-hour") }
+ (NSUnitSpeed *)knots { LINEAR(NSUnitSpeed, @"kn", 0.514444, 0, 0x903, "knot") }
+ (NSUnitSpeed *)metersPerSecond { LINEAR(NSUnitSpeed, @"m/s", 1, 0, 0x900, "meter-per-second") }
+ (NSUnitSpeed *)milesPerHour { LINEAR(NSUnitSpeed, @"mph", 0.44704, 0, 0x902, "mile-per-hour") }
@end

@implementation NSUnitTemperature
+ (NSString *)icuType { return @"temperature"; }
+ (instancetype)baseUnit { return (id)[NSUnitTemperature kelvin]; }
+ (NSUnitTemperature *)celsius { LINEAR(NSUnitTemperature, @"°C", 1, 273.15, 0xa00, "celsius") }
+ (NSUnitTemperature *)fahrenheit { LINEAR(NSUnitTemperature, @"°F", 0.55555555555556, 255.37222222222428, 0xa01, "fahrenheit") }
+ (NSUnitTemperature *)kelvin { LINEAR(NSUnitTemperature, @"K", 1, 0, 0xa02, "kelvin") }
@end

@implementation NSUnitVolume
+ (NSString *)icuType { return @"volume"; }
+ (instancetype)baseUnit { return (id)[NSUnitVolume liters]; }
+ (NSUnitVolume *)acreFeet { LINEAR(NSUnitVolume, @"af", 1233000, 0, 0xb0d, "acre-foot") }
+ (NSUnitVolume *)bushels { LINEAR(NSUnitVolume, @"bsh", 35.2391, 0, 0xb0e, "bushel") }
+ (NSUnitVolume *)centiliters { LINEAR(NSUnitVolume, @"cL", 0.01, 0, 0xb04, "centiliter") }
+ (NSUnitVolume *)cubicCentimeters { LINEAR(NSUnitVolume, @"cm³", 0.001, 0, 0xb08, "cubic-centimeter") }
+ (NSUnitVolume *)cubicDecimeters { LINEAR(NSUnitVolume, @"dm³", 1, 0, -1, NULL) }
+ (NSUnitVolume *)cubicFeet { LINEAR(NSUnitVolume, @"ft³", 28.3168, 0, 0xb0b, "cubic-foot") }
+ (NSUnitVolume *)cubicInches { LINEAR(NSUnitVolume, @"in³", 0.0163871, 0, 0xb0a, "cubic-inch") }
+ (NSUnitVolume *)cubicKilometers { LINEAR(NSUnitVolume, @"km³", 1000000000000, 0, 0xb01, "cubic-kilometer") }
+ (NSUnitVolume *)cubicMeters { LINEAR(NSUnitVolume, @"m³", 1000, 0, 0xb09, "cubic-meter") }
+ (NSUnitVolume *)cubicMiles { LINEAR(NSUnitVolume, @"mi³", 4168000000000, 0, 0xb02, "cubic-mile") }
+ (NSUnitVolume *)cubicMillimeters { LINEAR(NSUnitVolume, @"mm³", 1e-06, 0, -1, NULL) }
+ (NSUnitVolume *)cubicYards { LINEAR(NSUnitVolume, @"yd³", 764.555, 0, 0xb0c, "cubic-yard") }
+ (NSUnitVolume *)cups { LINEAR(NSUnitVolume, @"cup", 0.24, 0, 0xb12, "cup") }
+ (NSUnitVolume *)deciliters { LINEAR(NSUnitVolume, @"dL", 0.1, 0, 0xb05, "deciliter") }
+ (NSUnitVolume *)fluidOunces { LINEAR(NSUnitVolume, @"fl oz", 0.0295735, 0, 0xb11, "fluid-ounce") }
+ (NSUnitVolume *)gallons { LINEAR(NSUnitVolume, @"gal", 3.78541, 0, 0xb15, "gallon") }
+ (NSUnitVolume *)imperialFluidOunces { LINEAR(NSUnitVolume, @"fl oz", 0.0284131, 0, 0xb11, "fluid-ounce-imperial") }
+ (NSUnitVolume *)imperialGallons { LINEAR(NSUnitVolume, @"gal", 4.54609, 0, 0xb18, "gallon-imperial") }
+ (NSUnitVolume *)imperialPints { LINEAR(NSUnitVolume, @"pt", 0.568261, 0, 0xb13, "pint") }
+ (NSUnitVolume *)imperialQuarts { LINEAR(NSUnitVolume, @"qt", 1.13652, 0, 0xb14, "quart") }
+ (NSUnitVolume *)imperialTablespoons { LINEAR(NSUnitVolume, @"tbsp", 0.0177582, 0, 0xb10, "tablespoon") }
+ (NSUnitVolume *)imperialTeaspoons { LINEAR(NSUnitVolume, @"tsp", 0.00591939, 0, 0xb0f, "teaspoon") }
+ (NSUnitVolume *)kiloliters { LINEAR(NSUnitVolume, @"kL", 1000, 0, -1, NULL) }
+ (NSUnitVolume *)liters { LINEAR(NSUnitVolume, @"L", 1, 0, 0xb00, "liter") }
+ (NSUnitVolume *)megaliters { LINEAR(NSUnitVolume, @"ML", 1000000, 0, 0xb07, "megaliter") }
+ (NSUnitVolume *)metricCups { LINEAR(NSUnitVolume, @"metric cup", 0.25, 0, 0xb16, "cup-metric") }
+ (NSUnitVolume *)milliliters { LINEAR(NSUnitVolume, @"mL", 0.001, 0, 0xb03, "milliliter") }
+ (NSUnitVolume *)pints { LINEAR(NSUnitVolume, @"pt", 0.473176, 0, 0xb13, "pint-metric") }
+ (NSUnitVolume *)quarts { LINEAR(NSUnitVolume, @"qt", 0.946353, 0, 0xb14, "quart") }
+ (NSUnitVolume *)tablespoons { LINEAR(NSUnitVolume, @"tbsp", 0.0147868, 0, 0xb10, "tablespoon") }
+ (NSUnitVolume *)teaspoons { LINEAR(NSUnitVolume, @"tsp", 0.00492892, 0, 0xb0f, "teaspoon") }
@end

@implementation NSUnitConcentrationMass (FinchMoles)
+ (NSUnitConcentrationMass *)millimolesPerLiterWithGramsPerMole:(double)gramsPerMole
{
    NSUnitConverterLinear *c = [[NSUnitConverterLinear alloc] initWithCoefficient:gramsPerMole * 0.001];
    NSUnitConcentrationMass *u = [[self alloc] initWithSpecifier:0x1202 symbol:@"mmol/L" converter:c];
    [c release];
    return [u autorelease];
}
@end

/* The unit an ICU measure unit stands for (NSMeasurementFormatter.m); US
 * units where the imperial ones share the ICU unit, and the base unit of
 * the dimension for the others (days, say, and Apple's for milligrams per
 * deciliter too). */
NSDimension *
FinchUnitForSpecifier(NSInteger specifier)
{
    switch (specifier) {
    case 0x0: return [NSUnitAcceleration gravity];
    case 0x1: return [NSUnitAcceleration metersPerSecondSquared];
    case 0x100: return [NSUnitAngle degrees];
    case 0x101: return [NSUnitAngle arcMinutes];
    case 0x102: return [NSUnitAngle arcSeconds];
    case 0x103: return [NSUnitAngle radians];
    case 0x104: return [NSUnitAngle revolutions];
    case 0x200: return [NSUnitArea squareMeters];
    case 0x201: return [NSUnitArea squareKilometers];
    case 0x202: return [NSUnitArea squareFeet];
    case 0x203: return [NSUnitArea squareMiles];
    case 0x204: return [NSUnitArea acres];
    case 0x205: return [NSUnitArea hectares];
    case 0x206: return [NSUnitArea squareCentimeters];
    case 0x207: return [NSUnitArea squareInches];
    case 0x208: return [NSUnitArea squareYards];
    case 0x404: return [NSUnitDuration hours];
    case 0x405: return [NSUnitDuration minutes];
    case 0x406: return [NSUnitDuration seconds];
    case 0x407: return [NSUnitDuration milliseconds];
    case 0x408: return [NSUnitDuration microseconds];
    case 0x409: return [NSUnitDuration nanoseconds];
    case 0x500: return [NSUnitLength meters];
    case 0x501: return [NSUnitLength centimeters];
    case 0x502: return [NSUnitLength kilometers];
    case 0x503: return [NSUnitLength millimeters];
    case 0x504: return [NSUnitLength picometers];
    case 0x505: return [NSUnitLength feet];
    case 0x506: return [NSUnitLength inches];
    case 0x507: return [NSUnitLength miles];
    case 0x508: return [NSUnitLength yards];
    case 0x509: return [NSUnitLength lightyears];
    case 0x50a: return [NSUnitLength decimeters];
    case 0x50b: return [NSUnitLength micrometers];
    case 0x50c: return [NSUnitLength nanometers];
    case 0x50d: return [NSUnitLength nauticalMiles];
    case 0x50e: return [NSUnitLength fathoms];
    case 0x50f: return [NSUnitLength furlongs];
    case 0x510: return [NSUnitLength astronomicalUnits];
    case 0x511: return [NSUnitLength parsecs];
    case 0x512: return [NSUnitLength scandinavianMiles];
    case 0x600: return [NSUnitMass grams];
    case 0x601: return [NSUnitMass kilograms];
    case 0x602: return [NSUnitMass ounces];
    case 0x603: return [NSUnitMass poundsMass];
    case 0x604: return [NSUnitMass stones];
    case 0x605: return [NSUnitMass micrograms];
    case 0x606: return [NSUnitMass milligrams];
    case 0x607: return [NSUnitMass metricTons];
    case 0x608: return [NSUnitMass shortTons];
    case 0x609: return [NSUnitMass carats];
    case 0x60a: return [NSUnitMass ouncesTroy];
    case 0x700: return [NSUnitPower watts];
    case 0x701: return [NSUnitPower kilowatts];
    case 0x702: return [NSUnitPower horsepower];
    case 0x703: return [NSUnitPower milliwatts];
    case 0x704: return [NSUnitPower megawatts];
    case 0x705: return [NSUnitPower gigawatts];
    case 0x800: return [NSUnitPressure hectopascals];
    case 0x801: return [NSUnitPressure inchesOfMercury];
    case 0x802: return [NSUnitPressure millibars];
    case 0x803: return [NSUnitPressure millimetersOfMercury];
    case 0x804: return [NSUnitPressure poundsForcePerSquareInch];
    case 0x806: return [NSUnitPressure kilopascals];
    case 0x807: return [NSUnitPressure megapascals];
    case 0x809: return [NSUnitPressure bars];
    case 0x900: return [NSUnitSpeed metersPerSecond];
    case 0x901: return [NSUnitSpeed kilometersPerHour];
    case 0x902: return [NSUnitSpeed milesPerHour];
    case 0x903: return [NSUnitSpeed knots];
    case 0xa00: return [NSUnitTemperature celsius];
    case 0xa01: return [NSUnitTemperature fahrenheit];
    case 0xa02: return [NSUnitTemperature kelvin];
    case 0xb00: return [NSUnitVolume liters];
    case 0xb01: return [NSUnitVolume cubicKilometers];
    case 0xb02: return [NSUnitVolume cubicMiles];
    case 0xb03: return [NSUnitVolume milliliters];
    case 0xb04: return [NSUnitVolume centiliters];
    case 0xb05: return [NSUnitVolume deciliters];
    case 0xb07: return [NSUnitVolume megaliters];
    case 0xb08: return [NSUnitVolume cubicCentimeters];
    case 0xb09: return [NSUnitVolume cubicMeters];
    case 0xb0a: return [NSUnitVolume cubicInches];
    case 0xb0b: return [NSUnitVolume cubicFeet];
    case 0xb0c: return [NSUnitVolume cubicYards];
    case 0xb0d: return [NSUnitVolume acreFeet];
    case 0xb0e: return [NSUnitVolume bushels];
    case 0xb0f: return [NSUnitVolume teaspoons];
    case 0xb10: return [NSUnitVolume tablespoons];
    case 0xb11: return [NSUnitVolume fluidOunces];
    case 0xb12: return [NSUnitVolume cups];
    case 0xb13: return [NSUnitVolume pints];
    case 0xb14: return [NSUnitVolume quarts];
    case 0xb15: return [NSUnitVolume gallons];
    case 0xb16: return [NSUnitVolume metricCups];
    case 0xb18: return [NSUnitVolume imperialGallons];
    case 0xc00: return [NSUnitEnergy calories];
    case 0xc01: return [NSUnitEnergy foodcalories];
    case 0xc02: return [NSUnitEnergy joules];
    case 0xc03: return [NSUnitEnergy kilocalories];
    case 0xc04: return [NSUnitEnergy kilojoules];
    case 0xc05: return [NSUnitEnergy kilowattHours];
    case 0xd01: return [NSUnitFuelEfficiency milesPerGallon];
    case 0xd02: return [NSUnitFuelEfficiency litersPer100Kilometers];
    case 0xd03: return [NSUnitFuelEfficiency milesPerImperialGallon];
    case 0xe00: return [NSUnitInformationStorage bits];
    case 0xe01: return [NSUnitInformationStorage bytes];
    case 0xe02: return [NSUnitInformationStorage gigabits];
    case 0xe03: return [NSUnitInformationStorage gigabytes];
    case 0xe04: return [NSUnitInformationStorage kilobits];
    case 0xe05: return [NSUnitInformationStorage kilobytes];
    case 0xe06: return [NSUnitInformationStorage megabits];
    case 0xe07: return [NSUnitInformationStorage megabytes];
    case 0xe08: return [NSUnitInformationStorage terabits];
    case 0xe09: return [NSUnitInformationStorage terabytes];
    case 0xe0a: return [NSUnitInformationStorage petabytes];
    case 0xf00: return [NSUnitElectricCurrent amperes];
    case 0xf01: return [NSUnitElectricCurrent milliamperes];
    case 0xf02: return [NSUnitElectricResistance ohms];
    case 0xf03: return [NSUnitElectricPotentialDifference volts];
    case 0x1000: return [NSUnitFrequency hertz];
    case 0x1001: return [NSUnitFrequency kilohertz];
    case 0x1002: return [NSUnitFrequency megahertz];
    case 0x1003: return [NSUnitFrequency gigahertz];
    case 0x1100: return [NSUnitIlluminance lux];
    case 0x1203: return [NSUnitDispersion partsPerMillion];
    }
    switch (specifier >> 8) {
    case 0x0: return [NSUnitAcceleration baseUnit];
    case 0x1: return [NSUnitAngle baseUnit];
    case 0x2: return [NSUnitArea baseUnit];
    case 0x4: return [NSUnitDuration baseUnit];
    case 0x5: return [NSUnitLength baseUnit];
    case 0x6: return [NSUnitMass baseUnit];
    case 0x7: return [NSUnitPower baseUnit];
    case 0x8: return [NSUnitPressure baseUnit];
    case 0x9: return [NSUnitSpeed baseUnit];
    case 0xa: return [NSUnitTemperature baseUnit];
    case 0xb: return [NSUnitVolume baseUnit];
    case 0xc: return [NSUnitEnergy baseUnit];
    case 0xd: return [NSUnitFuelEfficiency baseUnit];
    case 0xe: return [NSUnitInformationStorage baseUnit];
    case 0x10: return [NSUnitFrequency baseUnit];
    case 0x11: return [NSUnitIlluminance baseUnit];
    case 0x12: return [NSUnitConcentrationMass baseUnit];
    }
    return nil;
}

/* MARK: - Natural scale */

/* Systems as Apple numbers them. */
enum { METRIC = 0, UK = 1, US = 2, NO_SYSTEM = 3 };

/* The value of `m` in its dimension's base unit. */
static double
base_value(NSMeasurement *m)
{
    return [[(NSDimension *)[m unit] converter] baseUnitValueFromValue:[m doubleValue]];
}

/* `m` in the last of `units` (smallest first) whose threshold its base
 * value is above, as Apple's picks it. */
static NSMeasurement *
scale(NSMeasurement *m, NSUInteger n, NSDimension *const units[], const double above[])
{
    double base = base_value(m);
    NSDimension *pick = units[0];
    for (NSUInteger i = 1; i < n; i++)
        if (base > above[i]) pick = units[i];
    return [m measurementByConvertingToUnit:pick];
}

#define SCALE(m, above, ...) do { \
    NSDimension *const units_[] = { __VA_ARGS__ }; \
    return scale(m, sizeof units_ / sizeof units_[0], units_, above); \
} while (0)

/* Apple's thresholds, in base units: just under 1000 is "1000 and up". */
static const double milli_unit_kilo[] = { 0, 0.001, 999.99999999999989 };
static const double unit_kilo[] = { 0, 999.99999999999989 };

#define METRIC_SCALE(Class, milli, unit, kilo) \
    @implementation Class (FinchNaturalScale) \
    + (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system \
    { \
        if (system == METRIC) SCALE(m, milli_unit_kilo, [Class milli], [Class unit], [Class kilo]); \
        return [super _measurementWithNaturalScale:m system:system]; \
    } \
    @end

METRIC_SCALE(NSUnitElectricCharge, milliampereHours, coulombs, kiloampereHours)
METRIC_SCALE(NSUnitElectricCurrent, milliamperes, amperes, kiloamperes)
METRIC_SCALE(NSUnitElectricPotentialDifference, millivolts, volts, kilovolts)
METRIC_SCALE(NSUnitElectricResistance, milliohms, ohms, kiloohms)
METRIC_SCALE(NSUnitFrequency, millihertz, hertz, kilohertz)
METRIC_SCALE(NSUnitPower, milliwatts, watts, kilowatts)

@implementation NSUnitArea (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double imperial[] = { 0, 0.046451520000000003, 83.612735999999998, 2590136.7551999995 };
    if (system == METRIC) SCALE(m, milli_unit_kilo, [self squareCentimeters], [self squareMeters], [self squareKilometers]);
    if (system == UK || system == US) SCALE(m, imperial, [self squareInches], [self squareFeet], [self squareYards], [self squareMiles]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitDuration (FinchNaturalScale)
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double above[] = { 0, 59.999999999999993, 3599.9999999999995 };
    if (system == NO_SYSTEM) SCALE(m, above, [self seconds], [self minutes], [self hours]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitEnergy (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double calories[] = { 0, 4183.9999999999991 };
    if (system == METRIC) SCALE(m, unit_kilo, [self joules], [self kilojoules]);
    if (system == UK || system == US) SCALE(m, calories, [self calories], [self kilocalories]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitInformationStorage (FinchNaturalScale)
/* In every system: bytes and their decimal multiples, or, for a value in
 * a binary unit (kibibits included), the binary multiples. A value under
 * a byte keeps its unit. */
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double decimal[] = { 0, 999.49999999999989, 999499.99999999988, 999949999.99999976, 999994999999.99988,
        999994999999999.88, 9.9999499999999987e+17, 9.999949999999999e+20, 9.9999499999999993e+23 };
    static const double binary[] = { 0, 1023.4999999999999, 1048063.9999999999, 1073689395.1999999, 1099506259066.8799,
        1125894409284485, 1.1529158751073126e+18, 1.1805858561098881e+21, 1.2089199166565254e+24 };
    if (base_value(m) < 1) return [super _measurementWithNaturalScale:m system:system];
    NSUnit *u = [m unit];
    if ([u isEqual:[self kibibits]] || [u isEqual:[self mebibits]] || [u isEqual:[self gibibits]] || [u isEqual:[self tebibits]]
        || [u isEqual:[self pebibits]] || [u isEqual:[self exbibits]] || [u isEqual:[self zebibits]] || [u isEqual:[self yobibits]]
        || [u isEqual:[self kibibytes]] || [u isEqual:[self mebibytes]] || [u isEqual:[self gibibytes]] || [u isEqual:[self tebibytes]]
        || [u isEqual:[self pebibytes]] || [u isEqual:[self exbibytes]] || [u isEqual:[self zebibytes]] || [u isEqual:[self yobibytes]])
        SCALE(m, binary, [self bytes], [self kibibytes], [self mebibytes], [self gibibytes], [self tebibytes], [self pebibytes],
            [self exbibytes], [self zebibytes], [self yobibytes]);
    SCALE(m, decimal, [self bytes], [self kilobytes], [self megabytes], [self gigabytes], [self terabytes], [self petabytes],
        [self exabytes], [self zettabytes], [self yottabytes]);
}
@end

@implementation NSUnitLength (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double imperial[] = { 0, 1.9812000000000001, 274.31999999999999, 804.67199999999991 };
    if (system == METRIC) SCALE(m, milli_unit_kilo, [self millimeters], [self meters], [self kilometers]);
    if (system == UK || system == US) SCALE(m, imperial, [self inches], [self feet], [self yards], [self miles]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitMass (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double metric[] = { 0, 0.001 }, uk[] = { 0, 1.5875725000000001 }, us[] = { 0, 0.40823280000000001, 453.59199999999993 };
    if (system == METRIC) SCALE(m, metric, [self grams], [self kilograms]);
    if (system == UK) SCALE(m, uk, [self ouncesTroy], [self stones]);
    if (system == US) SCALE(m, us, [self ounces], [self poundsMass], [self shortTons]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitPressure (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    if (system == METRIC) SCALE(m, unit_kilo, [self newtonsPerMetersSquared], [self kilopascals]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitVolume (FinchNaturalScale)
+ (BOOL)supportsRegionalPreference { return YES; }
+ (NSMeasurement *)_measurementWithNaturalScale:(NSMeasurement *)m system:(NSInteger)system
{
    static const double uk[] = { 0, 4.5460959999999995 }, us[] = { 0, 0.12, 1.9199999999999997, 3.5999999999999996 };
    if (system == METRIC) SCALE(m, milli_unit_kilo, [self centiliters], [self liters], [self kiloliters]);
    if (system == UK) SCALE(m, uk, [self imperialFluidOunces], [self imperialGallons]);
    if (system == US) SCALE(m, us, [self fluidOunces], [self cups], [self quarts], [self gallons]);
    return [super _measurementWithNaturalScale:m system:system];
}
@end

@implementation NSUnitConcentrationMass (FinchRegional)
+ (BOOL)supportsRegionalPreference { return YES; }
@end
@implementation NSUnitFuelEfficiency (FinchRegional)
+ (BOOL)supportsRegionalPreference { return YES; }
@end
@implementation NSUnitSpeed (FinchRegional)
+ (BOOL)supportsRegionalPreference { return YES; }
@end
@implementation NSUnitTemperature (FinchRegional)
+ (BOOL)supportsRegionalPreference { return YES; }
@end

/* MARK: - NSMeasurement */

@implementation NSMeasurement

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithDoubleValue:(double)doubleValue unit:(NSUnit *)unit
{
    if (![unit isKindOfClass:[NSUnit class]]) {
        [self release];
        FinchRaise(NSInvalidArgumentException, "Must pass in an NSUnit object!");
    }
    if ((self = [super init])) {
        _doubleValue = doubleValue;
        _unit = [unit copy];
    }
    return self;
}

- (void)dealloc
{
    [_unit release];
    [super dealloc];
}

- (NSUnit *)unit { return _unit; }
- (double)doubleValue { return _doubleValue; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSMeasurement class]]) return NO;
    return [_unit isEqual:[object unit]] && _doubleValue == [object doubleValue];
}

- (NSUInteger)hash { return hash_double(_doubleValue); }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> value: %f unit: %@", [self class], self, _doubleValue, [_unit symbol]];
}

/* Dimensional units convert within their dimension; a unit that isn't one
 * converts only to itself. */
- (BOOL)canBeConvertedToUnit:(NSUnit *)unit
{
    if (![_unit isKindOfClass:[NSDimension class]]) return YES;
    return [_unit _effectiveUnitClass] == [unit _effectiveUnitClass];
}

- (NSMeasurement *)measurementByConvertingToUnit:(NSUnit *)unit
{
    if ([_unit isEqual:unit]) return [[[NSMeasurement alloc] initWithDoubleValue:_doubleValue unit:unit] autorelease];
    if (![_unit isKindOfClass:[NSDimension class]])
        FinchRaise(NSInvalidArgumentException, "Cannot convert differing units that are non-dimensional! lhs: %@ rhs: %@",
            [_unit class], [unit class]);
    if ([_unit _effectiveUnitClass] != [unit _effectiveUnitClass])
        FinchRaise(NSInvalidArgumentException, "Cannot convert measurements of differing unit types! self: %@ unit: %@",
            [_unit class], [unit class]);
    double base = [[(NSDimension *)_unit converter] baseUnitValueFromValue:_doubleValue];
    double value = [[(NSDimension *)unit converter] valueFromBaseUnitValue:base];
    return [[[NSMeasurement alloc] initWithDoubleValue:value unit:unit] autorelease];
}

/* Equal units add as they are; otherwise both go to the base unit. */
- (NSMeasurement *)_performOperation:(int)op withMeasurement:(NSMeasurement *)other
{
    const char *verb = op ? "subtract" : "add";
    NSUnit *unit = [other unit];
    double a = _doubleValue, b = [other doubleValue];
    if (![_unit isEqual:unit]) {
        if (![_unit isKindOfClass:[NSDimension class]])
            FinchRaise(NSInvalidArgumentException, "Cannot %s differing units that are non-dimensional! lhs: %@ rhs: %@",
                verb, [_unit class], [unit class]);
        if ([_unit _effectiveUnitClass] != [unit _effectiveUnitClass])
            FinchRaise(NSInvalidArgumentException, "Cannot %s measurements of differing unit types! lhs: %@ rhs: %@",
                verb, [_unit class], [unit class]);
        if (![unit isKindOfClass:[_unit class]])
            FinchRaise(NSInvalidArgumentException, "Cannot %s measurements of differing unit types!", verb);
        a = [[(NSDimension *)_unit converter] baseUnitValueFromValue:a];
        b = [[(NSDimension *)unit converter] baseUnitValueFromValue:b];
        unit = [[_unit class] baseUnit];
    }
    return [[[NSMeasurement alloc] initWithDoubleValue:op ? a - b : a + b unit:unit] autorelease];
}

- (NSMeasurement *)measurementByAddingMeasurement:(NSMeasurement *)measurement
{
    return [self _performOperation:0 withMeasurement:measurement];
}

- (NSMeasurement *)measurementBySubtractingMeasurement:(NSMeasurement *)measurement
{
    return [self _performOperation:1 withMeasurement:measurement];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_doubleValue forKey:@"NS.value"];
    [coder encodeObject:_unit forKey:@"NS.unit"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSUnit *unit = [coder decodeObjectOfClass:[NSUnit class] forKey:@"NS.unit"];
    if (!unit) {
        [self release];
        return nil;
    }
    return [self initWithDoubleValue:[coder decodeDoubleForKey:@"NS.value"] unit:unit];
}

@end
