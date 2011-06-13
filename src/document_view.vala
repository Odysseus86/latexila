/*
 * This file is part of LaTeXila.
 *
 * Copyright © 2010 Sébastien Wilmet
 *
 * LaTeXila is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * LaTeXila is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with LaTeXila.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gtk;

public class DocumentView : Gtk.SourceView
{
    public const double SCROLL_MARGIN = 0.02;

    private GLib.Settings editor_settings;
    private Pango.FontDescription font_desc;

    public DocumentView (Document doc)
    {
        this.buffer = doc;

        doc.notify["readonly"].connect ((d, p) =>
        {
            this.editable = ! ((Document) d).readonly;
        });

        wrap_mode = WrapMode.WORD;
        auto_indent = true;
        indent_width = -1;

        /* settings */
        editor_settings = new GLib.Settings ("org.gnome.latexila.preferences.editor");

        set_font_from_settings ();

        // tab width
        uint tmp;
        editor_settings.get ("tabs-size", "u", out tmp);
        tab_width = tmp;

        insert_spaces_instead_of_tabs = editor_settings.get_boolean ("insert-spaces");
        show_line_numbers = editor_settings.get_boolean ("display-line-numbers");
        highlight_current_line = editor_settings.get_boolean ("highlight-current-line");
        doc.highlight_matching_brackets =
            editor_settings.get_boolean ("bracket-matching");
        doc.set_style_scheme_from_string (editor_settings.get_string ("scheme"));
        set_smart_home_end (SourceSmartHomeEndType.AFTER);

        // completion
        try
        {
            CompletionProvider provider = CompletionProvider.get_default ();
            completion.add_provider (provider);
            //completion.show_icons = false;
            completion.remember_info_visibility = true;

            // Gtk-CRITICAL with that, see bug #629055
            //completion.show_headers = false;

            buffer.notify["cursor-position"].connect (() =>
            {
                provider.hide_calltip_window ();
            });
        }
        catch (GLib.Error e)
        {
            stderr.printf ("Error completion: %s\n", e.message);
        }

        // smart backspace (if indent with spaces)
        key_press_event.connect (on_backspace);
    }

    public void scroll_to_cursor (double margin = 0.25)
    {
        scroll_to_mark (this.buffer.get_insert (), margin, false, 0, 0);
    }

    public void cut_selection ()
    {
        return_if_fail (this.buffer != null);
        var clipboard = get_clipboard (Gdk.SELECTION_CLIPBOARD);
        this.buffer.cut_clipboard (clipboard, ! ((Document) this.buffer).readonly);
        scroll_to_cursor (SCROLL_MARGIN);
        grab_focus ();
    }

    public void copy_selection ()
    {
        return_if_fail (this.buffer != null);
        var clipboard = get_clipboard (Gdk.SELECTION_CLIPBOARD);
        this.buffer.copy_clipboard (clipboard);
        grab_focus ();
    }

    public void my_paste_clipboard ()
    {
        return_if_fail (this.buffer != null);
        var clipboard = get_clipboard (Gdk.SELECTION_CLIPBOARD);
        this.buffer.paste_clipboard (clipboard, null,
            ! ((Document) this.buffer).readonly);
        scroll_to_cursor (SCROLL_MARGIN);
        grab_focus ();
    }

    public void delete_selection ()
    {
        return_if_fail (this.buffer != null);
        this.buffer.delete_selection (true, ! ((Document) this.buffer).readonly);
        scroll_to_cursor (SCROLL_MARGIN);
    }

    public void my_select_all ()
    {
        return_if_fail (this.buffer != null);
        TextIter start, end;
        this.buffer.get_bounds (out start, out end);
        this.buffer.select_range (start, end);
    }

    // TODO when GtkSourceView 3.0 is released we can delete this function
    public uint my_get_visual_column (TextIter iter)
    {
        uint column = 0;
        uint tab_width = get_tab_width ();

        TextIter position = iter;
        position.set_visible_line_offset (0);

        while (! iter.equal (position))
        {
            if (position.get_char () == '\t')
                column += (tab_width - (column % tab_width));
            else
                column++;

            if (! position.forward_char ())
                break;
        }

        return column;
    }

    public void set_font_from_settings ()
    {
        string font;
        if (editor_settings.get_boolean ("use-default-font"))
            font = AppSettings.get_default ().system_font;
        else
            font = editor_settings.get_string ("editor-font");

        set_font_from_string (font);
    }

    public void set_font_from_string (string font)
    {
        font_desc = Pango.FontDescription.from_string (font);
        modify_font (font_desc);
    }

    public void enlarge_font ()
    {
        // this is not saved in the settings
        font_desc.set_size (font_desc.get_size () + Pango.SCALE);
        modify_font (font_desc);
    }

    public void shrink_font ()
    {
        // this is not saved in the settings
        font_desc.set_size (font_desc.get_size () - Pango.SCALE);
        modify_font (font_desc);
    }

    public string get_indentation_style ()
    {
        if (insert_spaces_instead_of_tabs)
            return string.nfill (tab_width, ' ');
        return "\t";
    }

    private bool on_backspace (Gdk.EventKey event)
    {
        // See GDK_KEY_BackSpace in gdk/gdkkeysyms.h (not available in Vala)

        // TODO connect/disconnect the signal when settings in gsettings change
        if (! editor_settings.get_boolean ("insert-spaces")
            || ! editor_settings.get_boolean ("forget-no-tabs")
            || event.keyval != 0xff08
            || buffer.has_selection
            || tab_width == 1)

            // propagate the event further
            return false;

        /* forget that we are not using tabulations */
        TextIter iter_start, iter_insert;
        buffer.get_iter_at_mark (out iter_insert, buffer.get_insert ());
        buffer.get_iter_at_line (out iter_start, iter_insert.get_line ());

        string text = buffer.get_text (iter_start, iter_insert, false);

        if (text == "")
            return false;

        int nb_chars_to_delete = 0;
        bool between = true; // between two indent

        for (long i = 0 ; i < text.length ; i++)
        {
            if (text[i] == '\t')
            {
                nb_chars_to_delete = 1;
                between = true;
                continue;
            }

            // smart backspace only at the beginnig of a line, not inside it
            if (text[i] != ' ')
                return false;

            // it's a space

            if (between)
            {
                nb_chars_to_delete = 1;
                between = false;
                continue;
            }

            nb_chars_to_delete++;
            if (nb_chars_to_delete == tab_width)
                between = true;
        }

        iter_start = iter_insert;
        if (! iter_start.backward_chars (nb_chars_to_delete))
            return false;

        buffer.begin_user_action ();
        buffer.delete_range (iter_start, iter_insert);
        buffer.end_user_action ();

        return true;
    }
}
