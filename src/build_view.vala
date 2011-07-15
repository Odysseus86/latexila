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

public enum PartitionState
{
    RUNNING,
    SUCCEEDED,
    FAILED,
    ABORTED
}

public enum BuildMessageType
{
    ERROR,
    WARNING,
    BADBOX,
    OTHER
}

public struct BuildIssue
{
    public string message;
    public BuildMessageType message_type;
    public string? filename;

    // no line: -1
    // if end_line is -1, end_line takes the same value as start_line
    public int start_line;
    public int end_line;
}

public class BuildView : HBox
{
    enum BuildInfo
    {
        ICON,
        MESSAGE,
        MESSAGE_TYPE,
        WEIGHT,
        BASENAME,
        FILENAME,
        START_LINE,
        END_LINE,
        LINE,
        N_COLUMNS
    }

    public bool show_errors { get; set; }
    public bool show_warnings { get; set; }
    public bool show_badboxes { get; set; }

    private unowned MainWindow main_window;
    private TreeStore store;
    private TreeModelFilter filtered_model;
    private TreeView view;
    private unowned ToggleAction action_view_bottom_panel;

    public BuildView (MainWindow main_window, Toolbar toolbar,
        ToggleAction view_bottom_panel)
    {
        this.main_window = main_window;
        this.action_view_bottom_panel = view_bottom_panel;

        store = new TreeStore (BuildInfo.N_COLUMNS,
            typeof (string),    // icon (stock-id)
            typeof (string),    // message
            typeof (BuildMessageType),
            typeof (int),       // weight (normal or bold)
            typeof (string),    // basename
            typeof (string),    // filename
            typeof (int),       // start line
            typeof (int),       // end line
            typeof (string)     // line (same as start line but for display)
        );

        /* filter errors/warnings/badboxes */
        filtered_model = new TreeModelFilter (store, null);
        filtered_model.set_visible_func ((model, iter) =>
        {
            BuildMessageType msg_type;
            model.get (iter, BuildInfo.MESSAGE_TYPE, out msg_type, -1);

            switch (msg_type)
            {
                case BuildMessageType.ERROR:
                    return show_errors;
                case BuildMessageType.WARNING:
                    return show_warnings;
                case BuildMessageType.BADBOX:
                    return show_badboxes;
                default:
                    return true;
            }
        });

        this.notify["show-errors"].connect (() => filtered_model.refilter ());
        this.notify["show-warnings"].connect (() => filtered_model.refilter ());
        this.notify["show-badboxes"].connect (() => filtered_model.refilter ());

        /* create tree view */
        view = new TreeView.with_model (filtered_model);

        TreeViewColumn column_job = new TreeViewColumn ();
        column_job.title = _("Job");

        CellRendererPixbuf renderer_pixbuf = new CellRendererPixbuf ();
        column_job.pack_start (renderer_pixbuf, false);
        column_job.add_attribute (renderer_pixbuf, "stock-id", BuildInfo.ICON);

        CellRendererText renderer_text = new CellRendererText ();
        renderer_text.weight_set = true;
        renderer_text.editable = true;
        renderer_text.editable_set = true;
        column_job.pack_start (renderer_text, true);
        column_job.add_attribute (renderer_text, "text", BuildInfo.MESSAGE);
        column_job.add_attribute (renderer_text, "weight", BuildInfo.WEIGHT);

        view.append_column (column_job);

        view.insert_column_with_attributes (-1, _("File"), new CellRendererText (),
            "text", BuildInfo.BASENAME);
        view.insert_column_with_attributes (-1, _("Line"), new CellRendererText (),
            "text", BuildInfo.LINE);

        view.set_tooltip_column (BuildInfo.FILENAME);

        // selection
        TreeSelection select = view.get_selection ();
        select.set_mode (SelectionMode.SINGLE);
        select.set_select_function ((select, model, path, path_currently_selected) =>
        {
            // always allow deselect
            if (path_currently_selected)
                return true;

            return select_row (model, path);
        });

        // double-click
        view.row_activated.connect ((path) => select_row (filtered_model, path));

        // close button
        Button close_button = new Button ();
        close_button.relief = ReliefStyle.NONE;
        close_button.focus_on_click = false;
        close_button.tooltip_text = _("Hide panel");
        close_button.add (new Image.from_stock (Stock.CLOSE, IconSize.MENU));
        close_button.clicked.connect (() =>
        {
            this.hide ();
            action_view_bottom_panel.active = false;
        });

        // with a scrollbar
        Widget sw = Utils.add_scrollbar (view);
        pack_start (sw);

        VBox vbox = new VBox (false, 0);
        vbox.pack_start (close_button, false, false);
        vbox.pack_start (toolbar);
        pack_start (vbox, false, false);
    }

    private bool select_row (TreeModel model, TreePath path)
    {
        TreeIter iter;
        if (! model.get_iter (out iter, path))
            // the row is not selected
            return false;

        BuildMessageType msg_type;
        string filename;
        int start_line, end_line;

        model.get (iter,
            BuildInfo.MESSAGE_TYPE, out msg_type,
            BuildInfo.FILENAME, out filename,
            BuildInfo.START_LINE, out start_line,
            BuildInfo.END_LINE, out end_line,
            -1);

        if (msg_type != BuildMessageType.OTHER && filename != null
            && filename.length > 0)
        {
            jump_to_file (filename, start_line, end_line);

            // the row is selected
            return true;
        }

        // maybe it's a parent, so we can show or hide its children
        else if (msg_type == BuildMessageType.OTHER)
        {
            if (model.iter_has_child (iter))
            {
                if (view.is_row_expanded (path))
                    view.collapse_row (path);
                else
                    view.expand_to_path (path);

                // the row is not selected
                return false;
            }
        }

        // the row is selected, so we can copy/paste its content
        return true;
    }

    private void jump_to_file (string filename, int start_line, int end_line)
    {
        File file = File.new_for_path (filename);
        DocumentTab tab = main_window.open_document (file);

        // If the file was not yet opened, it takes some time. If we try to select the
        // lines when the file is not fully charged, the lines are simply not selected.
        Utils.flush_queue ();

        if (start_line != -1)
        {
            // start_line and end_line begins at 1 (from rubber),
            // but select_lines() begins at 0 (gtksourceview)
            int end = end_line != -1 ? end_line - 1 : start_line;
            tab.document.select_lines (start_line - 1, end);
        }
    }

    public void clear ()
    {
        store.clear ();
        view.columns_autosize ();
    }

    public TreeIter add_partition (string msg, PartitionState state, TreeIter? parent,
        bool bold = false)
    {
        TreeIter iter;
        store.append (out iter, parent);
        store.set (iter,
            BuildInfo.ICON,         get_icon_from_state (state),
            BuildInfo.MESSAGE,      msg,
            BuildInfo.MESSAGE_TYPE, BuildMessageType.OTHER,
            BuildInfo.WEIGHT,       bold ? 800 : 400,
            -1);

        view.expand_all ();

        return iter;
    }

    public void set_partition_state (TreeIter partition_id, PartitionState state)
    {
        store.set (partition_id, BuildInfo.ICON, get_icon_from_state (state), -1);
    }

    public void append_issues (TreeIter partition_id, Gee.ArrayList<BuildIssue?> issues)
    {
        foreach (BuildIssue issue in issues)
        {
            TreeIter iter;
            store.append (out iter, partition_id);
            store.set (iter,
                BuildInfo.ICON,         get_icon_from_msg_type (issue.message_type),
                BuildInfo.MESSAGE,      issue.message,
                BuildInfo.MESSAGE_TYPE, issue.message_type,
                BuildInfo.WEIGHT,       400,
                BuildInfo.BASENAME,     issue.filename != null ?
                                        Path.get_basename (issue.filename) : null,
                BuildInfo.FILENAME,     issue.filename,
                BuildInfo.START_LINE,   issue.start_line,
                BuildInfo.END_LINE,     issue.end_line,
                BuildInfo.LINE,         issue.start_line != -1 ?
                                        issue.start_line.to_string () : null,
                -1);
        }

        view.expand_all ();
    }

    private string? get_icon_from_state (PartitionState state)
    {
        switch (state)
        {
            case PartitionState.RUNNING:
                return Stock.EXECUTE;
            case PartitionState.SUCCEEDED:
                return Stock.APPLY;
            case PartitionState.FAILED:
                return Stock.DIALOG_ERROR;
            case PartitionState.ABORTED:
                return Stock.STOP;
            default:
                return_val_if_reached (null);
        }
    }

    private string? get_icon_from_msg_type (BuildMessageType type)
    {
        switch (type)
        {
            case BuildMessageType.ERROR:
                return Stock.DIALOG_ERROR;
            case BuildMessageType.WARNING:
                return Stock.DIALOG_WARNING;
            case BuildMessageType.BADBOX:
                return "badbox";
            case BuildMessageType.OTHER:
                return null;
            default:
                return_val_if_reached (null);
        }
    }

    public new void show ()
    {
        base.show ();
        action_view_bottom_panel.active = true;
    }
}
