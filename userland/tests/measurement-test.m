/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-measurement-test: NSUnit and its dimensions (every unit Apple's
 * Foundation has: symbol, converter, conversions), NSMeasurement
 * (conversion, arithmetic, equality, hashing, errors, secure coding) and
 * NSMeasurementFormatter (en_US and a few other locales, every style and
 * option), one result per line so runs against Apple's Foundation and
 * Finch's can be diffed. Addresses are masked.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <regex.h>

static const char *
masked(NSString *s)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:NULL];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"0x?"].UTF8String;
}

/* nil, out of the compiler's sight (nonnull arguments). */
static id nothing(void) { return [NSNull null] == nil ? @1 : nil; }

#define M(v, u) [[NSMeasurement alloc] initWithDoubleValue:(v) unit:(u)]

static void
try(const char *label, id (^block)(void))
{
    @try {
        printf("%s: %s\n", label, masked([block() description] ?: @"(nil)"));
    } @catch (NSException *e) {
        printf("%s: %s %s\n", label, e.name.UTF8String, masked(e.reason));
    }
}

static const struct { NSString *cls, *units; } all_units[] = {
    { @"NSUnitAcceleration", @"gravity metersPerSecondSquared" },
    { @"NSUnitAngle", @"arcMinutes arcSeconds degrees gradians radians revolutions" },
    { @"NSUnitArea", @"acres ares hectares squareCentimeters squareFeet squareInches squareKilometers squareMegameters squareMeters squareMicrometers squareMiles squareMillimeters squareNanometers squareYards" },
    { @"NSUnitConcentrationMass", @"gramsPerLiter milligramsPerDeciliter" },
    { @"NSUnitDispersion", @"partsPerMillion" },
    { @"NSUnitDuration", @"hours microseconds milliseconds minutes nanoseconds picoseconds seconds" },
    { @"NSUnitElectricCharge", @"ampereHours coulombs kiloampereHours megaampereHours microampereHours milliampereHours" },
    { @"NSUnitElectricCurrent", @"amperes kiloamperes megaamperes microamperes milliamperes" },
    { @"NSUnitElectricPotentialDifference", @"kilovolts megavolts microvolts millivolts volts" },
    { @"NSUnitElectricResistance", @"kiloohms megaohms microohms milliohms ohms" },
    { @"NSUnitEnergy", @"calories foodcalories joules kilocalories kilojoules kilowattHours" },
    { @"NSUnitFrequency", @"framesPerSecond gigahertz hertz kilohertz megahertz microhertz millihertz nanohertz terahertz" },
    { @"NSUnitFuelEfficiency", @"litersPer100Kilometers milesPerGallon milesPerImperialGallon" },
    { @"NSUnitIlluminance", @"lux" },
    { @"NSUnitInformationStorage", @"bits bytes exabits exabytes exbibits exbibytes gibibits gibibytes gigabits gigabytes kibibits kibibytes kilobits kilobytes mebibits mebibytes megabits megabytes nibbles pebibits pebibytes petabits petabytes tebibits tebibytes terabits terabytes yobibits yobibytes yottabits yottabytes zebibits zebibytes zettabits zettabytes" },
    { @"NSUnitLength", @"astronomicalUnits centimeters decameters decimeters fathoms feet furlongs hectometers inches kilometers lightyears megameters meters micrometers miles millimeters nanometers nauticalMiles parsecs picometers scandinavianMiles yards" },
    { @"NSUnitMass", @"carats centigrams decigrams grams kilograms metricTons micrograms milligrams nanograms ounces ouncesTroy picograms poundsMass shortTons slugs stones" },
    { @"NSUnitPower", @"femtowatts gigawatts horsepower kilowatts megawatts microwatts milliwatts nanowatts picowatts terawatts watts" },
    { @"NSUnitPressure", @"bars gigapascals hectopascals inchesOfMercury kilopascals megapascals millibars millimetersOfMercury newtonsPerMetersSquared poundsForcePerSquareInch" },
    { @"NSUnitSpeed", @"kilometersPerHour knots metersPerSecond milesPerHour" },
    { @"NSUnitTemperature", @"celsius fahrenheit kelvin" },
    { @"NSUnitVolume", @"acreFeet bushels centiliters cubicCentimeters cubicDecimeters cubicFeet cubicInches cubicKilometers cubicMeters cubicMiles cubicMillimeters cubicYards cups deciliters fluidOunces gallons imperialFluidOunces imperialGallons imperialPints imperialQuarts imperialTablespoons imperialTeaspoons kiloliters liters megaliters metricCups milliliters pints quarts tablespoons teaspoons" },
};

static void
units(void)
{
    for (size_t i = 0; i < sizeof all_units / sizeof all_units[0]; i++) {
        Class c = NSClassFromString(all_units[i].cls);
        NSDimension *base = [c baseUnit];
        printf("%s base %s %s\n", all_units[i].cls.UTF8String, base.symbol.UTF8String, NSStringFromClass([base class]).UTF8String);
        for (NSString *name in [all_units[i].units componentsSeparatedByString:@" "]) {
            NSDimension *u = [c performSelector:NSSelectorFromString(name)];
            NSUnitConverter *cv = u.converter;
            NSString *conv = [cv isKindOfClass:[NSUnitConverterLinear class]]
                ? [NSString stringWithFormat:@"%.17g %.17g", [(NSUnitConverterLinear *)cv coefficient], [(NSUnitConverterLinear *)cv constant]]
                : [cv description];
            printf("  %s \"%s\" %s %s | %s | %.17g %.17g | same %d eqbase %d hash %lu copy %d\n", name.UTF8String, u.symbol.UTF8String,
                NSStringFromClass([u class]).UTF8String, NSStringFromClass([cv class]).UTF8String, masked(conv),
                [cv baseUnitValueFromValue:2.5], [cv valueFromBaseUnitValue:2.5], u == [c performSelector:NSSelectorFromString(name)],
                [u isEqual:base], (unsigned long)u.hash, [u copy] == u);
        }
    }
    NSUnitConcentrationMass *mm = [NSUnitConcentrationMass millimolesPerLiterWithGramsPerMole:180.16];
    printf("mmol %s %s %.17g\n", NSStringFromClass([mm class]).UTF8String, mm.symbol.UTF8String, [(NSUnitConverterLinear *)mm.converter coefficient]);
}

static void
units_and_converters(void)
{
    NSUnit *w = [[NSUnit alloc] initWithSymbol:@"wid"];
    printf("unit %s hash %lu eq %d %d\n", masked(w.description), (unsigned long)w.hash, [w isEqual:[[NSUnit alloc] initWithSymbol:@"wid"]],
        [w isEqual:[[NSUnit alloc] initWithSymbol:@"w"]]);
    NSDimension *x = [[NSUnitLength alloc] initWithSymbol:@"m" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:1]];
    NSDimension *y = [[NSUnitMass alloc] initWithSymbol:@"m" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:1]];
    NSDimension *k = [[NSUnitLength alloc] initWithSymbol:@"km" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:999]];
    printf("dim %s eq %d %d %d %d %d %d hash %lu %lu\n", masked(x.description), [x isEqual:NSUnitLength.meters], [NSUnitLength.meters isEqual:x],
        [x isEqual:y], [x isEqual:[[NSUnit alloc] initWithSymbol:@"m"]], [[[NSUnit alloc] initWithSymbol:@"m"] isEqual:x],
        [k isEqual:NSUnitLength.kilometers], (unsigned long)x.hash, (unsigned long)k.hash);
    printf("nil symbol %s\n", masked([[NSUnit alloc] initWithSymbol:@"m"].description));
    NSUnitConverterLinear *l = [[NSUnitConverterLinear alloc] initWithCoefficient:2 constant:3];
    printf("linear %s %g %g hash %lu eq %d %d\n", masked(l.description), [l baseUnitValueFromValue:5], [l valueFromBaseUnitValue:13], (unsigned long)l.hash,
        [l isEqual:[[NSUnitConverterLinear alloc] initWithCoefficient:2 constant:3]], [l isEqual:[[NSUnitConverterLinear alloc] initWithCoefficient:2]]);
    printf("linear new %s\n", masked([NSUnitConverterLinear new].description));
    printf("static converters %s | %s\n", masked(NSUnitLength.meters.converter.description), masked(NSUnitTemperature.celsius.converter.description));
    NSUnitConverter *plain = [NSUnitConverter new];
    printf("converter %s %g %g\n", masked(plain.description), [plain baseUnitValueFromValue:5], [plain valueFromBaseUnitValue:7]);
    NSUnitConverter *r = NSUnitFuelEfficiency.milesPerGallon.converter;
    printf("reciprocal %s %.17g %.17g hash %lu\n", masked(r.description), [r baseUnitValueFromValue:30], [r valueFromBaseUnitValue:0], (unsigned long)r.hash);
    try("NSDimension baseUnit", ^id { return [NSDimension baseUnit]; });
    try("NSUnit init", ^id { return [(id)[NSUnit alloc] init]; });
    try("NSMeasurement init", ^id { return [(id)[NSMeasurement alloc] init]; });
    try("nil unit", ^id { return M(1, nothing()); });
    try("nil converter", ^id { return [[NSUnitLength alloc] initWithSymbol:@"x" converter:nothing()].description; });
}

static void
measurements(void)
{
    NSUnit *w = [[NSUnit alloc] initWithSymbol:@"m"], *n = [[NSUnit alloc] initWithSymbol:@"n"];
    NSUnitLength *s = [[NSUnitLength alloc] initWithSymbol:@"s" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:3]];
    NSDimension *q = [[NSDimension alloc] initWithSymbol:@"q" converter:[NSUnitConverterLinear new]];
    try("km+m", ^id { return [M(1, NSUnitLength.kilometers) measurementByAddingMeasurement:M(500, NSUnitLength.meters)]; });
    try("m+km", ^id { return [M(500, NSUnitLength.meters) measurementByAddingMeasurement:M(1, NSUnitLength.kilometers)]; });
    try("km-m", ^id { return [M(1, NSUnitLength.kilometers) measurementBySubtractingMeasurement:M(500, NSUnitLength.meters)]; });
    try("km+km", ^id { return [M(2, NSUnitLength.kilometers) measurementByAddingMeasurement:M(3, NSUnitLength.kilometers)]; });
    try("C+F", ^id { return [M(20, NSUnitTemperature.celsius) measurementByAddingMeasurement:M(20, NSUnitTemperature.fahrenheit)]; });
    try("m+g", ^id { return [M(1, NSUnitLength.meters) measurementByAddingMeasurement:M(1, NSUnitMass.grams)]; });
    try("m-g", ^id { return [M(1, NSUnitLength.meters) measurementBySubtractingMeasurement:M(1, NSUnitMass.grams)]; });
    try("w+n", ^id { return [M(1, w) measurementByAddingMeasurement:M(1, n)]; });
    try("w-g", ^id { return [M(1, w) measurementBySubtractingMeasurement:M(1, NSUnitMass.grams)]; });
    try("g+w", ^id { return [M(1, NSUnitMass.grams) measurementByAddingMeasurement:M(1, w)]; });
    try("w+w", ^id { return [M(2, w) measurementByAddingMeasurement:M(3, [[NSUnit alloc] initWithSymbol:@"m"])]; });
    try("m+s", ^id { return [M(1, NSUnitLength.meters) measurementByAddingMeasurement:M(1, s)]; });
    try("s-m", ^id { return [M(1, s) measurementBySubtractingMeasurement:M(2, NSUnitLength.meters)]; });
    try("g+nil", ^id { return [M(1, NSUnitMass.grams) measurementByAddingMeasurement:nothing()]; });
    try("m->ft", ^id { return [NSString stringWithFormat:@"%.17g", [M(1, NSUnitLength.meters) measurementByConvertingToUnit:NSUnitLength.feet].doubleValue]; });
    try("F->C", ^id { return [NSString stringWithFormat:@"%.17g", [M(100, NSUnitTemperature.fahrenheit) measurementByConvertingToUnit:NSUnitTemperature.celsius].doubleValue]; });
    try("C->F", ^id { return [M(20, NSUnitTemperature.celsius) measurementByConvertingToUnit:NSUnitTemperature.fahrenheit]; });
    try("mpg->imperial", ^id { return [NSString stringWithFormat:@"%.17g", [M(30, NSUnitFuelEfficiency.milesPerGallon) measurementByConvertingToUnit:NSUnitFuelEfficiency.milesPerImperialGallon].doubleValue]; });
    try("mpg->L/100km", ^id { return [M(30, NSUnitFuelEfficiency.milesPerGallon) measurementByConvertingToUnit:NSUnitFuelEfficiency.litersPer100Kilometers]; });
    try("KiB->MB", ^id { return [M(5000, NSUnitInformationStorage.kibibytes) measurementByConvertingToUnit:NSUnitInformationStorage.megabytes]; });
    try("m->g", ^id { return [M(1, NSUnitLength.meters) measurementByConvertingToUnit:NSUnitMass.grams]; });
    try("m->w", ^id { return [M(1, NSUnitLength.meters) measurementByConvertingToUnit:w]; });
    try("w->g", ^id { return [M(1, w) measurementByConvertingToUnit:NSUnitMass.grams]; });
    try("w->w", ^id { return [M(1, w) measurementByConvertingToUnit:w]; });
    try("w->n", ^id { return [M(1, w) measurementByConvertingToUnit:n]; });
    try("g->nil", ^id { return [M(1, NSUnitMass.grams) measurementByConvertingToUnit:nothing()]; });
    try("q->q", ^id { return [M(1, q) measurementByConvertingToUnit:q]; });
    printf("canConvert %d %d %d %d %d %d\n", [M(1, NSUnitLength.meters) canBeConvertedToUnit:NSUnitLength.miles],
        [M(1, NSUnitLength.meters) canBeConvertedToUnit:NSUnitMass.grams], [M(1, NSUnitLength.meters) canBeConvertedToUnit:s],
        [M(1, NSUnitLength.meters) canBeConvertedToUnit:q], [M(1, w) canBeConvertedToUnit:n], [M(1, NSUnitMass.grams) canBeConvertedToUnit:w]);
    printf("equal %d %d %d %d %d\n", [M(1, NSUnitLength.kilometers) isEqual:M(1, NSUnitLength.kilometers)],
        [M(1000, NSUnitLength.meters) isEqual:M(1, NSUnitLength.kilometers)], [M(1, NSUnitLength.meters) isEqual:M(1, [[NSUnitLength alloc] initWithSymbol:@"m" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:1]])],
        [M(1, NSUnitLength.meters) isEqual:@1], [M(2, w) isEqual:M(2, [[NSUnit alloc] initWithSymbol:@"m"])]);
    for (NSNumber *v in @[@0, @1, @1.5, @0.3, @-2, @1e20, @123.456])
        printf("hash %g %lu %lu\n", v.doubleValue, (unsigned long)[M(v.doubleValue, NSUnitLength.meters) hash], (unsigned long)[M(v.doubleValue, NSUnitMass.kilograms) hash]);
    NSMeasurement *m = M(1, NSUnitLength.meters);
    printf("copy %d desc %s\n", [m copy] == m, masked(m.description));
}

static void
coding(void)
{
    NSUnit *w = [[NSUnit alloc] initWithSymbol:@"w"];
    NSDimension *x = [[NSUnitLength alloc] initWithSymbol:@"m" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:1]];
    NSArray *root = @[M(1, NSUnitLength.kilometers), NSUnitTemperature.fahrenheit, x, w, [NSUnitConcentrationMass millimolesPerLiterWithGramsPerMole:18],
        NSUnitFuelEfficiency.milesPerGallon, M(2.5, w)];
    NSError *e = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:root requiringSecureCoding:YES error:&e];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    NSArray *objects = plist[@"$objects"];
    for (NSUInteger i = 0; i < objects.count; i++) {
        id o = objects[i];
        if (![o isKindOfClass:[NSDictionary class]]) { printf("object %lu %s\n", (unsigned long)i, [o description].UTF8String); continue; }
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in [[o allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id v = o[k];
            NSString *d = [v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]
                ? [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"(uid)";
            if ([NSStringFromClass([v class]) containsString:@"UID"]) d = @"(uid)";
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, d]];
        }
        printf("object %lu {%s}\n", (unsigned long)i, masked([parts componentsJoinedByString:@", "]));
    }
    NSArray *back = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSMeasurement class], [NSUnit class], nil]
        fromData:data error:&e];
    for (id o in back) printf("decoded %s %s\n", NSStringFromClass([o class]).UTF8String, masked([o description]));
    printf("decoded equal %d %d %d static %d\n", [back[0] isEqual:root[0]], [back[1] isEqual:root[1]], [back[5] isEqual:root[5]], back[1] == root[1]);
}

static NSArray *
samples(void)
{
    return @[M(5, NSUnitLength.kilometers), M(1, NSUnitLength.meters), M(0.3, NSUnitLength.meters), M(1500, NSUnitLength.meters),
        M(2, NSUnitLength.inches), M(-3, NSUnitLength.feet), M(250, NSUnitLength.miles), M(0, NSUnitLength.meters),
        M(20, NSUnitTemperature.celsius), M(98.6, NSUnitTemperature.fahrenheit), M(300, NSUnitTemperature.kelvin),
        M(3, NSUnitMass.kilograms), M(3, NSUnitMass.grams), M(12, NSUnitMass.stones), M(2000, NSUnitMass.kilograms),
        M(1, NSUnitVolume.liters), M(250, NSUnitVolume.milliliters), M(5, NSUnitVolume.gallons), M(3, NSUnitVolume.cubicMeters),
        M(90, NSUnitDuration.minutes), M(45, NSUnitDuration.seconds), M(7200, NSUnitDuration.seconds), M(2.5, NSUnitDuration.hours),
        M(100, NSUnitSpeed.kilometersPerHour), M(10, NSUnitSpeed.metersPerSecond), M(30, NSUnitSpeed.knots),
        M(1, NSUnitEnergy.kilojoules), M(2000, NSUnitEnergy.kilocalories), M(500, NSUnitEnergy.calories), M(3, NSUnitEnergy.kilowattHours),
        M(2048, NSUnitInformationStorage.bytes), M(5000, NSUnitInformationStorage.kibibytes), M(1.5, NSUnitInformationStorage.gigabytes),
        M(1, NSUnitAngle.radians), M(90, NSUnitAngle.degrees), M(1, NSUnitPressure.bars), M(1013.25, NSUnitPressure.hectopascals),
        M(7, NSUnitFuelEfficiency.litersPer100Kilometers), M(30, NSUnitFuelEfficiency.milesPerGallon),
        M(12345.678, NSUnitArea.squareMeters), M(2, NSUnitArea.acres), M(100, NSUnitArea.squareFeet),
        M(5, NSUnitElectricCurrent.milliamperes), M(1500, NSUnitElectricPotentialDifference.volts), M(0.5, NSUnitElectricResistance.ohms),
        M(2400, NSUnitFrequency.megahertz), M(3, NSUnitFrequency.hertz), M(1500, NSUnitPower.watts), M(150, NSUnitPower.horsepower),
        M(9.81, NSUnitAcceleration.metersPerSecondSquared), M(400, NSUnitIlluminance.lux), M(5, NSUnitDispersion.partsPerMillion),
        M(90, NSUnitConcentrationMass.milligramsPerDeciliter), M(6, NSUnitElectricCharge.coulombs), M(3000, NSUnitElectricCharge.milliampereHours),
        M(1, [[NSUnit alloc] initWithSymbol:@"wid"]),
        M(2, [[NSUnitLength alloc] initWithSymbol:@"zz" converter:[[NSUnitConverterLinear alloc] initWithCoefficient:2]]),
        M(2, NSUnitLength.megameters), M(4, NSUnitArea.squareMillimeters)];
}

static void
formatter(void)
{
    NSMeasurementFormatter *f = [NSMeasurementFormatter new];
    printf("defaults style %ld options %lu nf style %lu max %lu\n", (long)f.unitStyle, (unsigned long)f.unitOptions,
        (unsigned long)f.numberFormatter.numberStyle, (unsigned long)f.numberFormatter.maximumFractionDigits);
    NSArray *ms = samples();
    for (NSString *loc in @[@"en_US", @"en_GB", @"fr_FR", @"de_DE", @"ja_JP"]) {
        f.locale = [NSLocale localeWithLocaleIdentifier:loc];
        printf("locale %s nf %s\n", loc.UTF8String, f.numberFormatter.locale.localeIdentifier.UTF8String);
        for (NSUInteger opt = 0; opt < 8; opt++)
            for (NSInteger style = 1; style <= 3; style++) {
                f.unitOptions = opt;
                f.unitStyle = style;
                NSMutableArray *out = [NSMutableArray array];
                for (NSMeasurement *m in ms) [out addObject:[f stringFromMeasurement:m] ?: @"(nil)"];
                printf("%s opt %lu style %ld: %s\n", loc.UTF8String, (unsigned long)opt, (long)style, [out componentsJoinedByString:@" | "].UTF8String);
            }
        if (![loc isEqualToString:@"en_US"]) continue;
        for (NSInteger style = 1; style <= 3; style++) {
            f.unitStyle = style;
            for (size_t i = 0; i < sizeof all_units / sizeof all_units[0]; i++) {
                Class c = NSClassFromString(all_units[i].cls);
                NSMutableArray *out = [NSMutableArray array];
                for (NSString *name in [all_units[i].units componentsSeparatedByString:@" "])
                    [out addObject:[f stringFromUnit:[c performSelector:NSSelectorFromString(name)]] ?: @"(nil)"];
                printf("names %ld %s: %s\n", (long)style, all_units[i].cls.UTF8String, [out componentsJoinedByString:@" | "].UTF8String);
            }
        }
    }
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    f.unitOptions = NSMeasurementFormatterUnitOptionsProvidedUnit;
    f.unitStyle = NSFormattingUnitStyleMedium;
    printf("other objects [%s] [%s]\n", [f stringForObjectValue:@3].UTF8String, [f stringForObjectValue:nil].UTF8String);
    printf("unit names [%s] [%s]\n", [f stringFromUnit:[[NSUnit alloc] initWithSymbol:@"wid"]].UTF8String, [f stringFromUnit:NSUnitLength.megameters].UTF8String);
    NSNumberFormatter *nf = [NSNumberFormatter new];
    nf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    nf.maximumFractionDigits = 1;
    f.numberFormatter = nf;
    printf("number formatter copied %d: %s\n", f.numberFormatter == nf, [f stringFromMeasurement:M(1234.5678, NSUnitLength.meters)].UTF8String);
    f.numberFormatter.minimumFractionDigits = 2;
    f.numberFormatter.maximumFractionDigits = 2;
    printf("changed number formatter: %s\n", [f stringFromMeasurement:M(1234.5678, NSUnitLength.meters)].UTF8String);
    f.numberFormatter.roundingMode = NSNumberFormatterRoundUp;
    printf("rounding up: %s\n", [f stringFromMeasurement:M(1.231, NSUnitLength.meters)].UTF8String);
    f.numberFormatter = nil;
    printf("reset: %s nf %d\n", [f stringFromMeasurement:M(1234.5678, NSUnitLength.meters)].UTF8String, f.numberFormatter != nil);
    NSMeasurementFormatter *c = [f copy];
    printf("copy: %s\n", [c stringFromMeasurement:M(1234.5678, NSUnitLength.meters)].UTF8String);
    f.unitOptions = NSMeasurementFormatterUnitOptionsNaturalScale | NSMeasurementFormatterUnitOptionsProvidedUnit;
    for (NSNumber *v in @[@0.0005, @0.001, @0.0011, @0.5, @999, @1000, @1001, @123456])
        printf("scale %g: %s | %s | %s\n", v.doubleValue, [f stringFromMeasurement:M(v.doubleValue, NSUnitLength.meters)].UTF8String,
            [f stringFromMeasurement:M(v.doubleValue, NSUnitLength.feet)].UTF8String, [f stringFromMeasurement:M(v.doubleValue, NSUnitInformationStorage.kibibytes)].UTF8String);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 2 || strcmp(argv[1], "--no-path")) {
            Dl_info info;
            printf("Foundation: %s\n", dladdr((__bridge void *)[NSMeasurement class], &info) ? info.dli_fname : "?");
        }
        units();
        units_and_converters();
        measurements();
        coding();
        formatter();
    }
    return 0;
}
