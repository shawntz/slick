/// A view a command or action pushes onto the panel. Features describe pages; the host draws them,
/// owns the search field and the keyboard, and calls back into the page's source.
public enum Page: Sendable {
    /// Rows in sections, optionally with a detail pane.
    case list(ListPage)
    /// Cells in sections, for images and emoji.
    case grid(GridPage)
    /// One detail, possibly streamed, possibly with a follow-up field.
    case detail(DetailPage)
    /// A form the user fills in and submits.
    case form(FormPage)
}
