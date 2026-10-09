/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-containers-test: NSSplitView and NSTabView geometry and selection.
 * Prints everything; run against Apple's AppKit and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static void dump(NSSplitView *s){ printf("  split %s:", NSStringFromRect(s.frame).UTF8String); for (NSView *v in s.arrangedSubviews) printf(" %s%s", NSStringFromRect(v.frame).UTF8String, [s isSubviewCollapsed:v]?"(c)":""); printf("\n"); }
int main(void){@autoreleasepool{ setvbuf(stdout,NULL,_IOLBF,0); printf("%s\n", class_getImageName([NSSplitView class])); [NSApplication sharedApplication];
 NSSplitView *s=[[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,300,200)];
 printf("vertical %d style %ld thickness %g autosave %s arranges %d\n", s.isVertical, (long)s.dividerStyle, s.dividerThickness, s.autosaveName.UTF8String, s.arrangesAllSubviews);
 NSView *a=[[NSView alloc] initWithFrame:NSMakeRect(0,0,50,50)], *b=[[NSView alloc] initWithFrame:NSMakeRect(0,0,80,50)], *c=[[NSView alloc] initWithFrame:NSMakeRect(0,0,20,50)];
 [s addSubview:a]; [s addSubview:b]; dump(s); [s adjustSubviews]; dump(s);
 s.vertical=YES; [s adjustSubviews]; dump(s);
 [s addSubview:c]; [s adjustSubviews]; dump(s);
 [s setPosition:100 ofDividerAtIndex:0]; dump(s);
 [s setPosition:400 ofDividerAtIndex:1]; dump(s);
 printf("min %g max %g\n", [s minPossiblePositionOfDividerAtIndex:0], [s maxPossiblePositionOfDividerAtIndex:0]);
 [s setFrameSize:NSMakeSize(500,200)]; dump(s);
 s.dividerStyle=NSSplitViewDividerStyleThick; printf("thick %g\n", s.dividerThickness); s.dividerStyle=NSSplitViewDividerStylePaneSplitter; printf("pane %g\n", s.dividerThickness);
 [s setHoldingPriority:260 forSubviewAtIndex:0]; printf("holding %g %g\n", [s holdingPriorityForSubviewAtIndex:0], [s holdingPriorityForSubviewAtIndex:1]);
 NSTabView *t=[[NSTabView alloc] initWithFrame:NSMakeRect(0,0,300,200)]; printf("tab type %ld content %s items %ld\n",(long)t.tabViewType, NSStringFromRect(t.contentRect).UTF8String,(long)t.numberOfTabViewItems);
 NSTabViewItem *i1=[[NSTabViewItem alloc] initWithIdentifier:@"one"]; i1.label=@"One"; NSTabViewItem *i2=[[NSTabViewItem alloc] initWithIdentifier:@"two"]; i2.label=@"Two";
 [t addTabViewItem:i1]; [t addTabViewItem:i2]; printf("selected %s index %ld view %s\n", [t.selectedTabViewItem.identifier UTF8String], (long)[t indexOfTabViewItem:t.selectedTabViewItem], NSStringFromRect(i1.view.frame).UTF8String);
 [t selectNextTabViewItem:nil]; printf("after next %s\n", [t.selectedTabViewItem.identifier UTF8String]);
 t.tabViewType=NSNoTabsNoBorder; printf("noTabs content %s\n", NSStringFromRect(t.contentRect).UTF8String);
 t.tabViewType=NSTopTabsBezelBorder; printf("top content %s min %s\n", NSStringFromRect(t.contentRect).UTF8String, NSStringFromSize(t.minimumSize).UTF8String);
}}
