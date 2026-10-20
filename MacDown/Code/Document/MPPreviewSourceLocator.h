//
//  MPPreviewSourceLocator.h
//  MacDown 3000
//
//  Pure, headless-testable engine that maps a point in the rendered preview
//  back to a location in the Markdown source, for "Reveal in Editor"
//  (Issue #627).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MPPreviewSourceLocator : NSObject

/**
 * Return the source location of a point in the rendered preview.
 *
 * The preview's text nodes are anchored to the source in document order:
 * each node's text is searched for in the source after the previous match,
 * so repeated text resolves to the occurrence that was clicked. Text the
 * renderer generated (and that therefore cannot be found) leaves the search
 * position unchanged, and the result falls back to the nearest preceding
 * matched position.
 *
 * Known limitations:
 * - Generated text missed by reveal-in-editor.js's exclusion list moves the
 *   search position only if the source repeats it followed by the same
 *   neighbours within about 2000 characters.
 * - HTML entities other than the separator characters below (e.g. &eacute;)
 *   make their run of text unmatchable; clicks there land at the preceding
 *   matched position.
 * - Malformed raw-HTML tables with stray text outside cells are reordered by
 *   the HTML parser; nearby cells may resolve imprecisely.
 *
 * @param texts The values of the preview's collected text nodes, in
 *        document order, as returned by macdownRevealCollect().
 * @param footnotes For each entry in texts, the 0-based index of the
 *        footnote definition it is inside, or -1. nil means none are.
 * @param index Index of the clicked node in texts.
 * @param offset Offset of the clicked point within that node.
 * @param markdown The source. Pass an immutable copy; searching a string
 *        backed by an NSTextStorage is slow.
 * @return A location in markdown, at most markdown.length.
 */
+ (NSUInteger)sourceLocationForPreviewTexts:(NSArray<NSString *> *)texts
        footnotes:(nullable NSArray<NSNumber *> *)footnotes
        index:(NSUInteger)index offset:(NSUInteger)offset
        inMarkdown:(NSString *)markdown;

/**
 * The normalised form of markdown that text is searched for in: backslash
 * escapes dropped, tabs expanded as Hoedown expands them, and long HTML
 * comments, script and style blocks, and data: URIs removed. Exposed for
 * testing.
 */
+ (NSString *)searchableStringForMarkdown:(NSString *)markdown;

@end

NS_ASSUME_NONNULL_END
