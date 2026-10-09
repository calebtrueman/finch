/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-ruler-test: NSRulerView and NSRulerMarker: defaults, thicknesses, units,
 * markers, the scroll view's tiling of its rulers, and NSTextView's ruler (its
 * indent and tab markers and format bar). Run it against Apple's AppKit and
 * Finch's (DYLD_FRAMEWORK_PATH) and diff all but the first line.
 */
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>

static void dump(NSRulerView *r, const char *what) {
  printf("%s: class %s frame %s orient %ld units %s origin %g rule %g markersRes %g accRes %g required %g baseline %g client %s markers %lu acc %d\n", what,
   NSStringFromClass([r class]).UTF8String, NSStringFromRect(r.frame).UTF8String, (long)r.orientation, r.measurementUnits.UTF8String,
   r.originOffset, r.ruleThickness, r.reservedThicknessForMarkers, r.reservedThicknessForAccessoryView, r.requiredThickness, r.baselineLocation,
   r.clientView ? NSStringFromClass([r.clientView class]).UTF8String : "nil", (unsigned long)r.markers.count, r.accessoryView != nil);
}
int
main(void)
{
    @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); [NSApplication sharedApplication];
 Dl_info dl; dladdr((__bridge void*)[NSScrollView class],&dl); printf("%s\n", dl.dli_fname);
 printf("rulerViewClass %s\n", NSStringFromClass([NSScrollView rulerViewClass]).UTF8String);
 NSScrollView *sv=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,300)];
 sv.hasVerticalScroller=YES;
 NSView *doc=[[NSView alloc] initWithFrame:NSMakeRect(0,0,380,1000)]; sv.documentView=doc;
 NSRulerView *r=[[NSRulerView alloc] initWithScrollView:sv orientation:NSHorizontalRuler]; dump(r,"new h");
 NSRulerView *v=[[NSRulerView alloc] initWithScrollView:sv orientation:NSVerticalRuler]; dump(v,"new v");
 sv.hasHorizontalRuler=YES; printf("after hasH: h %s\n", NSStringFromClass([sv.horizontalRulerView class]).UTF8String);
 dump(sv.horizontalRulerView,"sv h");
 sv.hasVerticalRuler=YES; dump(sv.verticalRulerView,"sv v");
 printf("content %s\n", NSStringFromRect(sv.contentView.frame).UTF8String);
 sv.rulersVisible=YES; [sv tile];
 printf("visible: content %s h %s v %s super %d\n", NSStringFromRect(sv.contentView.frame).UTF8String, NSStringFromRect(sv.horizontalRulerView.frame).UTF8String, NSStringFromRect(sv.verticalRulerView.frame).UTF8String, sv.horizontalRulerView.superview==sv);
 dump(sv.horizontalRulerView,"vis h");
 { NSEdgeInsets i=sv.contentInsets, c=sv.contentView.contentInsets; printf("flipped %d autoInsets %d insets %g %g %g %g clip insets %g %g %g %g ruler flipped %d\n", sv.isFlipped, sv.automaticallyAdjustsContentInsets, i.top,i.left,i.bottom,i.right, c.top,c.left,c.bottom,c.right, sv.horizontalRulerView.isFlipped); }
 sv.automaticallyAdjustsContentInsets=NO; [sv tile]; printf("noauto: content %s h %s v %s\n", NSStringFromRect(sv.contentView.frame).UTF8String, NSStringFromRect(sv.horizontalRulerView.frame).UTF8String, NSStringFromRect(sv.verticalRulerView.frame).UTF8String);
 { NSEdgeInsets c=sv.contentView.contentInsets; printf("clip insets %g %g %g %g\n", c.top,c.left,c.bottom,c.right);}
 sv.automaticallyAdjustsContentInsets=YES;
 for (NSString *u in @[@"Inches",@"Centimeters",@"Points",@"Picas"]) { r.measurementUnits=u; printf("unit %s -> %s\n", u.UTF8String, r.measurementUnits.UTF8String);} 
 r.measurementUnits=@"Bogus"; printf("bogus -> %s\n", r.measurementUnits.UTF8String);
 [NSRulerView registerUnitWithName:@"Furlongs" abbreviation:@"fl" unitToPointsConversionFactor:10 stepUpCycle:@[@2] stepDownCycle:@[@0.5]];
 r.measurementUnits=@"Furlongs"; printf("furlongs -> %s\n", r.measurementUnits.UTF8String);
 NSImage *img=[NSImage imageWithSize:NSMakeSize(8,8) flipped:NO drawingHandler:^BOOL(NSRect d){return YES;}];
 NSRulerMarker *m=[[NSRulerMarker alloc] initWithRulerView:r markerLocation:50 image:img imageOrigin:NSMakePoint(4,0)];
 printf("marker loc %g movable %d removable %d dragging %d thick %g rect %s obj %p\n", m.markerLocation, m.movable, m.removable, m.isDragging, m.thicknessRequiredInRuler, NSStringFromRect(m.imageRectInRuler).UTF8String, m.representedObject);
 r.clientView=doc; printf("client set %s\n", NSStringFromClass([r.clientView class]).UTF8String); [r addMarker:m]; printf("markers %lu required %g\n",(unsigned long)r.markers.count, r.requiredThickness);
 r.reservedThicknessForMarkers=20; r.reservedThicknessForAccessoryView=10; printf("required %g\n", r.requiredThickness);
 [r removeMarker:m]; printf("markers %lu\n",(unsigned long)r.markers.count);
 r.ruleThickness=10; printf("rule %g required %g\n", r.ruleThickness, r.requiredThickness);
 NSView *acc=[[NSView alloc] initWithFrame:NSMakeRect(0,0,100,10)]; r.accessoryView=acc; printf("acc super %d\n", acc.superview==r);
 // text view
 NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 NSScrollView *ts=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,300)]; ts.hasVerticalScroller=YES;
 NSTextView *tv=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,385,300)]; ts.documentView=tv; w.contentView=ts;
 [tv setString:@"hello\tworld"]; [w makeFirstResponder:tv];
 printf("tv usesRuler %d visible %d hasH %d\n", tv.usesRuler, tv.isRulerVisible, ts.hasHorizontalRuler);
 [tv toggleRuler:nil];
 printf("after toggle: visible %d hasH %d rulersVisible %d hruler %s\n", tv.isRulerVisible, ts.hasHorizontalRuler, ts.rulersVisible, NSStringFromClass([ts.horizontalRulerView class]).UTF8String);
 if (ts.horizontalRulerView) { dump(ts.horizontalRulerView,"tv h"); 
   NSView *a=ts.horizontalRulerView.accessoryView; printf("acc %s %s subviews %lu\n", NSStringFromClass([a class]).UTF8String, NSStringFromRect(a.frame).UTF8String, (unsigned long)a.subviews.count);
   for (NSView *sub in a.subviews) printf("   sub %s %s\n", NSStringFromClass([sub class]).UTF8String, NSStringFromRect(sub.frame).UTF8String);
   /* (Apple's scroll pockets add a bottom inset in a window; Finch has none) */
   { NSEdgeInsets c=ts.contentView.contentInsets; printf("tv clip insets top %g left %g tv width %g\n", c.top,c.left, tv.frame.size.width);}
   printf("client is tv %d content %s\n", ts.horizontalRulerView.clientView==tv, NSStringFromRect(ts.contentView.frame).UTF8String);
   for (NSRulerMarker *mk in ts.horizontalRulerView.markers) printf("  mk loc %g obj %s mov %d rem %d img %s origin %s thick %g rect %s\n", mk.markerLocation, [[(id)mk.representedObject description] UTF8String], mk.movable, mk.removable, NSStringFromSize(mk.image.size).UTF8String, NSStringFromPoint(mk.imageOrigin).UTF8String, mk.thicknessRequiredInRuler, NSStringFromRect(mk.imageRectInRuler).UTF8String);
 }
 [tv toggleRuler:nil]; printf("toggle off: visible %d rulersVisible %d\n", tv.isRulerVisible, ts.rulersVisible);
    }
    return 0;
}
