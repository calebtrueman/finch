/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The theme AppKit draws in (FinchTheme.m, docs/design/FIELDWORK.md): Fieldwork
 * by default, Classic (Aqua-compatible values) when asked, or another theme file.
 */
#ifndef FINCH_THEME_H
#define FINCH_THEME_H

#import <AppKit/AppKit.h>

#define FINCH_THEME_HIDDEN __attribute__((visibility("hidden")))

/* The theme's name ("Fieldwork", "Classic", ...). */
FINCH_THEME_HIDDEN NSString *FinchThemeName(void);
/* Classic: AppKit draws with its Aqua-compatible values. */
FINCH_THEME_HIDDEN BOOL FinchThemeIsClassic(void);
/* Whether the current drawing appearance is a dark one (Night). */
FINCH_THEME_HIDDEN BOOL FinchThemeIsNight(void);
/* A system colour's value in the theme for the current appearance; NO if the theme leaves it out. */
FINCH_THEME_HIDDEN BOOL FinchThemeColorComponents(NSString *name, CGFloat rgba[4]);
/* A palette colour (canvas, slate, ink, graphite, accent, selection, outline, edgeHighlight), or nil. */
FINCH_THEME_HIDDEN NSColor *FinchThemePaletteColor(NSString *name);
/* A metric (window corner radii, outline widths, ...), or `fallback`. */
FINCH_THEME_HIDDEN CGFloat FinchThemeMetric(NSString *name, CGFloat fallback);

#endif
