/*
 * This file is part of LaTeXila.
 *
 * Copyright © 2010-2011 Sébastien Wilmet
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

public class GotoLine : HBox
{
    private unowned MainWindow main_window;
    private Entry entry;

    public GotoLine (MainWindow main_window)
    {
        this.main_window = main_window;
        spacing = 3;

        Button close_button = new Button ();
        pack_start (close_button, false, false, 0);
        close_button.set_relief (ReliefStyle.NONE);
        Image img = new Image.from_stock (Stock.CLOSE, IconSize.MENU);
        close_button.add (img);
        close_button.clicked.connect (() => hide ());

        Label label = new Label (_("Go to Line:"));
        pack_start (label, false, false, 2);

        entry = new Entry ();
        pack_start (entry, false, false, 0);
        entry.set_icon_from_stock (EntryIconPosition.SECONDARY, Stock.JUMP_TO);
        entry.set_icon_activatable (EntryIconPosition.SECONDARY, true);
        entry.set_tooltip_text (_("Line you want to move the cursor to"));
        entry.set_size_request (100, -1);
        entry.activate.connect (() => hide ());
        entry.icon_press.connect (() => hide ());
        entry.changed.connect (on_changed);
    }

    public new void show ()
    {
        entry.text = "";
        show_all ();
        entry.grab_focus ();
    }

    private void on_changed ()
    {
        if (entry.text_length == 0)
        {
            Utils.set_entry_error (entry, false);
            return;
        }

        string text = entry.get_text ();

        // check if all characters are digits
        for (int i = 0 ; i < text.length ; i++)
        {
            unichar c = text[i];
            if (! c.isdigit ())
            {
                Utils.set_entry_error (entry, true);
                return;
            }
        }

        int line = int.parse (text);
        bool error = ! main_window.active_document.goto_line (--line);
        Utils.set_entry_error (entry, error);
        main_window.active_view.scroll_to_cursor ();
    }
}

public class SearchAndReplace : GLib.Object
{
    private unowned MainWindow main_window;
    private Document working_document;

    private Widget widget;

    private Button button_arrow;
    private Arrow arrow;

    private Entry entry_find;
    private Label label_find_normal;
    private Label label_find_error;

    private Entry entry_replace;
    private Frame frame_replace;

    private HBox hbox_replace;

    private CheckMenuItem check_case_sensitive;
    private CheckMenuItem check_entire_word;

    private int min_nb_chars_for_incremental_search = 3;

    private bool search_and_replace_mode
    {
        get { return arrow.arrow_type == ArrowType.UP; }
    }

    private bool case_sensitive
    {
        get { return check_case_sensitive.get_active (); }
    }

    private bool entire_word
    {
        get { return check_entire_word.get_active (); }
    }

    public SearchAndReplace (MainWindow main_window)
    {
        this.main_window = main_window;

        string path = Path.build_filename (Config.DATA_DIR, "ui",
            "search_and_replace.ui");

        try
        {
            Builder builder = new Builder ();
            builder.add_from_file (path);

            /* get objects */
            widget = (Widget) builder.get_object ("search_and_replace");
            // we unparent the main widget because the ui file contains a window
            widget.unparent ();

            button_arrow = (Button) builder.get_object ("button_arrow");
            arrow = (Arrow) builder.get_object ("arrow");

            entry_find = (Entry) builder.get_object ("entry_find");
            label_find_normal = (Label) builder.get_object ("label_find_normal");
            label_find_error = (Label) builder.get_object ("label_find_error");
            EventBox eventbox_label1 = (EventBox) builder.get_object ("eventbox_label1");
            EventBox eventbox_label2 = (EventBox) builder.get_object ("eventbox_label2");
            Button button_clear_find = (Button) builder.get_object ("button_clear_find");

            entry_replace = (Entry) builder.get_object ("entry_replace");
            frame_replace = (Frame) builder.get_object ("frame_replace");
            Button button_clear_replace =
                (Button) builder.get_object ("button_clear_replace");
            Button button_replace = (Button) builder.get_object ("button_replace");
            Button button_replace_all =
                (Button) builder.get_object ("button_replace_all");

            hbox_replace = (HBox) builder.get_object ("hbox_replace");

            Button button_previous = (Button) builder.get_object ("button_previous");
            Button button_next = (Button) builder.get_object ("button_next");

            Button button_close = (Button) builder.get_object ("button_close");

            /* styles */
            Gdk.Color white;
            Gdk.Color.parse ("white", out white);
            eventbox_label1.modify_bg (StateType.NORMAL, white);
            eventbox_label2.modify_bg (StateType.NORMAL, white);

            /* options menu */
            Menu menu = new Menu ();
            check_case_sensitive = new CheckMenuItem.with_label (_("Case sensitive"));
            check_entire_word = new CheckMenuItem.with_label (_("Entire words only"));
            menu.append (check_case_sensitive);
            menu.append (check_entire_word);
            menu.show_all ();

            /* signal handlers */

            entry_find.icon_press.connect ((icon_pos, event) =>
            {
                // options menu
                if (icon_pos == EntryIconPosition.PRIMARY)
                    menu.popup (null, null, null, event.button.button, event.button.time);
            });

            button_arrow.clicked.connect (() =>
            {
                // search and replace -> search
                if (search_and_replace_mode)
                {
                    arrow.arrow_type = ArrowType.DOWN;
                    frame_replace.hide ();
                    hbox_replace.hide ();
                }

                // search -> search and replace
                else
                {
                    arrow.arrow_type = ArrowType.UP;
                    frame_replace.show ();
                    hbox_replace.show ();
                }
            });

            button_close.clicked.connect (hide);

            button_clear_find.clicked.connect (() => entry_find.text = "");
            button_clear_replace.clicked.connect (() => entry_replace.text = "");

            button_previous.clicked.connect (() =>
            {
                set_search_text (false);
                return_if_fail (working_document != null);
                working_document.search_backward ();
            });

            button_next.clicked.connect (search_forward);
            entry_find.activate.connect (search_forward);

            entry_find.changed.connect (() =>
            {
                bool sensitive = entry_find.text_length > 0;
                button_clear_find.sensitive = sensitive;
                button_previous.sensitive = sensitive;
                button_next.sensitive = sensitive;
                button_replace.sensitive = sensitive;
                button_replace_all.sensitive = sensitive;

                if (entry_find.text_length == 0)
                {
                    label_find_normal.hide ();
                    label_find_error.hide ();
                    clear_search ();
                }
                else if (entry_find.text_length >= min_nb_chars_for_incremental_search)
                    set_search_text ();
            });

            entry_replace.changed.connect (() =>
            {
                button_clear_replace.sensitive = entry_replace.text_length > 0;
            });

            check_case_sensitive.toggled.connect (() => set_search_text ());
            check_entire_word.toggled.connect (() => set_search_text ());

            button_replace.clicked.connect (replace);
            entry_replace.activate.connect (replace);

            button_replace_all.clicked.connect (() =>
            {
                return_if_fail (entry_find.text_length != 0);
                set_search_text ();
                working_document.replace_all (entry_replace.text);
            });

            entry_find.key_press_event.connect ((event) =>
            {
                // See GDK_KEY_* in gdk/gdkkeysyms.h (not available in Vala)
                switch (event.keyval)
                {
                    case 0xff09:    // GDK_KEY_Tab
                        // TAB in find => go to replace
                        show_search_and_replace ();
                        entry_replace.grab_focus ();
                        return true;

                    case 0xff1b:    // GDK_KEY_Escape
                        // Escape in find => select text and hide search
                        select_selected_search_text ();
                        hide ();
                        return true;

                    default:
                        // propagate the event further
                        return false;
                }
            });
        }
        catch (Error e)
        {
            stderr.printf ("Error search and replace: %s\n", e.message);
            Label label = new Label (e.message);
            label.set_line_wrap (true);
            widget = label;
        }

        widget.hide ();
    }

    public Widget get_widget ()
    {
        return widget;
    }

    public void show_search ()
    {
        arrow.arrow_type = ArrowType.DOWN;
        show ();
        frame_replace.hide ();
        hbox_replace.hide ();
    }

    public void show_search_and_replace ()
    {
        arrow.arrow_type = ArrowType.UP;
        show ();
    }

    private void show ()
    {
        return_if_fail (main_window.active_tab != null);

        widget.show_all ();
        label_find_normal.hide ();
        label_find_error.hide ();
        entry_find.grab_focus ();
        set_replace_sensitivity ();

        // if text is selected in the active document, and if this text contains no \n,
        // search this text
        Document doc = main_window.active_document;
        if (doc.get_selection_type () == SelectionType.ONE_LINE)
        {
            TextIter start, end;
            doc.get_selection_bounds (out start, out end);
            entry_find.text = doc.get_text (start, end, false);
        }

        main_window.notify["active-document"].connect (active_document_changed);
    }

    public void hide ()
    {
        widget.hide ();
        if (working_document != null)
            clear_search ();

        if (main_window.active_view != null)
            main_window.active_view.grab_focus ();

        main_window.notify["active-document"].disconnect (active_document_changed);
    }

    private void set_label_text (string text, bool error)
    {
        if (error)
        {
            label_find_error.set_text (text);
            label_find_error.show ();
            label_find_normal.hide ();
        }
        else
        {
            label_find_normal.set_text (text);
            label_find_normal.show ();
            label_find_error.hide ();
        }
    }

    private void set_search_text (bool select = true)
    {
        return_if_fail (main_window.active_document != null);

        if (entry_find.text_length == 0)
            return;

        if (main_window.active_document != working_document)
        {
            if (working_document != null)
                clear_search ();

            working_document = main_window.active_document;
            working_document.search_info_updated.connect (on_search_info_updated);
        }

        uint nb_matches, num_match;
        working_document.set_search_text (entry_find.text, case_sensitive, entire_word,
            out nb_matches, out num_match, select);

        on_search_info_updated (nb_matches != 0, nb_matches, num_match);
    }

    private void select_selected_search_text ()
    {
        return_if_fail (main_window.active_document != null);

        if (working_document != null);
            working_document.select_selected_search_text ();
    }

    private void search_forward ()
    {
        set_search_text (false);
        return_if_fail (working_document != null);
        working_document.search_forward ();
    }

    private void on_search_info_updated (bool selected, uint nb_matches, uint num_match)
    {
        if (selected)
            set_label_text (_("%u of %u").printf (num_match, nb_matches), false);
        else if (nb_matches == 0)
            set_label_text (_("Not found"), true);
        else if (nb_matches == 1)
            set_label_text (_("One match"), false);
        else
            set_label_text (_("%u matches").printf (nb_matches), false);
    }

    private void clear_search ()
    {
        if (working_document != null)
        {
            working_document.clear_search ();
            working_document.search_info_updated.disconnect (on_search_info_updated);
            working_document = null;
        }
    }

    private void active_document_changed ()
    {
        label_find_normal.hide ();
        label_find_error.hide ();
        set_replace_sensitivity ();
    }

    private void set_replace_sensitivity ()
    {
        bool readonly = main_window.active_document.readonly;
        frame_replace.set_sensitive (! readonly);
        hbox_replace.set_sensitive (! readonly);
    }

    private void replace ()
    {
        return_if_fail (entry_find.text_length != 0);
        set_search_text ();
        working_document.replace (entry_replace.text);
    }
}
