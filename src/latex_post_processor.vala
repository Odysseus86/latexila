/*
 * This file is part of LaTeXila.
 *
 * Copyright © 2011 Sébastien Wilmet
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

private class LatexPostProcessor : GLib.Object, PostProcessor
{
    public bool successful { get; protected set; }
    private Gee.ArrayList<BuildIssue?> issues = new Gee.ArrayList<BuildIssue?> ();

    private enum FilterStatus
    {
        START,
        BADBOX,
        WARNING,
        ERROR,
        ERROR_SEARCH_LINE,
        FILENAME,
        FILENAME_HEURISTIC
    }

    struct FileInStack
    {
        string filename;
        bool reliable;
    }

    private const int NO_LINE = -1;

    // the current message
    private BuildIssue msg;

    // if a message is splitted, we enter in a different status, so we fetch the end
    // of the message
    private FilterStatus status = FilterStatus.START;

    // if a message is splitted, the lines are concatenated in this buffer
    private string line_buf;
    private int nb_lines = 0;

    // if a filename is splitted into several lines
    private string filename_buf;

    // the stack containing the files that TeX is processing
    private SList<FileInStack?> stack_files = new SList<FileInStack?> ();

    // the directory where the document is compiled
    private string directory_path = null;

    // for statistics
    private int nb_badboxes = 0;
    private int nb_warnings = 0;
    private int nb_errors = 0;

    /* Regex */
    private static Regex? reg_badbox = null;
    private static Regex? reg_badbox_lines = null;
    private static Regex? reg_badbox_line = null;
    private static Regex? reg_badbox_output = null;

    private static Regex? reg_warning = null;
    private static Regex? reg_warning_no_file = null;
    private static Regex? reg_warning_line = null;
    private static Regex? reg_warning_international_line = null;

    private static Regex? reg_latex_error = null;
    private static Regex? reg_pdflatex_error = null;
    private static Regex? reg_tex_error = null;
    private static Regex? reg_error_line = null;

    private static Regex? reg_file_pop = null;
    private static Regex? reg_other_bytes = null;

    private static Regex? reg_spaces = null;

    public LatexPostProcessor ()
    {
        if (reg_badbox == null)
        {
            try
            {
                reg_badbox = new Regex ("^(Over|Under)full \\\\[hv]box");
                reg_badbox_lines = new Regex ("(.*) at lines ([0-9]+)--([0-9]+)");
                reg_badbox_line = new Regex ("(.*) at line ([0-9]+)");
                reg_badbox_output =
                    new Regex ("(.*)has occurred while \\output is active");

                reg_warning =
                    new Regex ("^(((! )?(La|pdf)TeX)|Package|Class) .*Warning[^:]*:[[:space:]]*(.*)",
                    RegexCompileFlags.CASELESS);
                reg_warning_no_file = new Regex ("(No file .*)");
                reg_warning_line = new Regex ("(.*) on input line ([0-9]+)\\.$");
                reg_warning_international_line = new Regex ("(.*)([0-9]+)\\.$");

                reg_latex_error = new Regex ("^! LaTeX Error: (.*)$");
                reg_pdflatex_error = new Regex ("^Error: pdflatex (.*)$");
                reg_tex_error = new Regex ("^! (.*)\\.$");
                reg_error_line = new Regex ("^l\\.([0-9]+)(.*)");

                reg_file_pop = new Regex ("(\\) )?:<-$");
                reg_other_bytes = new Regex ("([0-9]+) bytes");

                reg_spaces = new Regex ("[[:space:]]{2,}");
            }
            catch (RegexError e)
            {
                stderr.printf ("LatexPostProcessor: %s\n", e.message);
            }
        }

        reset_msg ();
    }

    public void process (File file, string output, int status)
    {
        successful = status == 0;
        directory_path = file.get_parent ().get_parse_name ();

        string[] lines = output.split ("\n");

        foreach (string line in lines)
            latex_output_filter (line);

        // stats
        msg.message = "%d %s, %d %s, %d %s".printf (
            nb_errors,   nb_errors   > 1 ? "errors"   : "error",
            nb_warnings, nb_warnings > 1 ? "warnings" : "warning",
            nb_badboxes, nb_badboxes > 1 ? "badboxes" : "badbox");
        msg.message_type = BuildMessageType.OTHER;
        add_msg (false);
    }

    public PostProcessorIssues[] get_issues ()
    {
        PostProcessorIssues[] pp_issues = new PostProcessorIssues[1];
        pp_issues[0].partition_msg = null;
        pp_issues[0].issues = issues;
        return pp_issues;
    }

    private void latex_output_filter (string line)
    {
        switch (status)
        {
            case FilterStatus.START:
                if (line.length == 0)
                    return;

                if (! (detect_badbox (line)
                       || detect_warning (line)
                       || detect_error (line)
                       || detect_other (line)))
                {
                    update_stack_file (line);
                }
                break;

            case FilterStatus.BADBOX:
                detect_badbox (line);
                break;

            case FilterStatus.WARNING:
                detect_warning (line);
                break;

            case FilterStatus.ERROR:
            case FilterStatus.ERROR_SEARCH_LINE:
                detect_error (line);
                break;

            case FilterStatus.FILENAME:
            case FilterStatus.FILENAME_HEURISTIC:
                update_stack_file (line);
                break;

            default:
                status = FilterStatus.START;
                break;
        }
    }

    private bool detect_badbox (string line)
    {
        switch (status)
        {
            case FilterStatus.START:
                if (! reg_badbox.match (line))
                    return false;

                msg.message_type = BuildMessageType.BADBOX;

                if (detect_badbox_line (line, false))
                    add_msg ();
                else
                {
                    line_buf = line;
                    nb_lines++;
                }

                return true;

            case FilterStatus.BADBOX:
                line_buf += line;
                nb_lines++;
                if (detect_badbox_line (line_buf, line.length == 0))
                {
                    add_msg ();
                    nb_lines = 0;
                }

                // the return value is not important here
                return true;

            default:
                return false;
        }
    }

    private bool detect_badbox_line (string badbox, bool current_line_is_empty)
    {
        if (reg_badbox_lines.match (badbox))
        {
            status = FilterStatus.START;
            string[] strings = reg_badbox_lines.split (badbox);
            msg.message = strings[1];
            int n1 = int.parse (strings[2]);
            int n2 = int.parse (strings[3]);

            if (n1 <= n2)
            {
                msg.start_line = n1;
                msg.end_line = n2;
            }
            else
            {
                msg.start_line = n2;
                msg.end_line = n1;
            }

            return true;
        }

        else if (reg_badbox_line.match (badbox))
        {
            status = FilterStatus.START;
            string[] strings = reg_badbox_line.split (badbox);
            msg.message = strings[1];
            msg.start_line = int.parse (strings[2]);
            return true;
        }

        else if (reg_badbox_output.match (badbox))
        {
            status = FilterStatus.START;
            string[] strings = reg_badbox_output.split (badbox);
            msg.message = strings[1];
            msg.start_line = NO_LINE;
            return true;
        }

        else if (nb_lines > 4 || current_line_is_empty)
        {
            status = FilterStatus.START;
            msg.message = badbox;
            msg.start_line = NO_LINE;
            return true;
        }

        status = FilterStatus.BADBOX;
        return false;
    }

    private bool detect_warning (string line)
    {
        switch (status)
        {
            case FilterStatus.START:
                if (reg_warning.match (line))
                {
                    msg.message_type = BuildMessageType.WARNING;

                    string[] strings = reg_warning.split (line);

                    if (detect_warning_line (strings[5], false))
                        add_msg ();
                    else
                    {
                        line_buf = strings[5];
                        nb_lines++;
                    }

                    return true;
                }

                else if (reg_warning_no_file.match (line))
                {
                    msg.message_type = BuildMessageType.WARNING;
                    string[] strings = reg_warning_no_file.split (line);
                    msg.message = strings[1];
                    msg.start_line = NO_LINE;
                    add_msg ();
                    return true;
                }

                return false;

            case FilterStatus.WARNING:
                line_buf += line;
                nb_lines++;
                if (detect_warning_line (line_buf, line.length == 0))
                {
                    add_msg ();
                    nb_lines = 0;
                }

                // the return value is not important here
                return true;

            default:
                return false;
        }
    }

    private bool detect_warning_line (string warning, bool current_line_is_empty)
    {
        if (reg_warning_line.match (warning))
        {
            status = FilterStatus.START;
            string[] strings = reg_warning_line.split (warning);
            msg.message = strings[1];
            msg.start_line = int.parse (strings[2]);
            return true;
        }

        else if (reg_warning_international_line.match (warning))
        {
            status = FilterStatus.START;
            string[] strings = reg_warning_international_line.split (warning);
            msg.message = strings[1];
            msg.start_line = int.parse (strings[2]);
            return true;
        }

        else if (warning[warning.length - 1] == '.')
        {
            status = FilterStatus.START;
            msg.message = warning;
            msg.start_line = NO_LINE;
            return true;
        }

        else if (nb_lines > 5 || current_line_is_empty)
        {
            status = FilterStatus.START;
            msg.message = warning;
            msg.start_line = NO_LINE;
            return true;
        }

        status = FilterStatus.WARNING;
        return false;
    }

    private bool detect_error (string line)
    {
        switch (status)
        {
            case FilterStatus.START:
                bool found = true;
                string tmp = null;

                if (reg_latex_error.match (line))
                {
                    string[] strings = reg_latex_error.split (line);
                    tmp = strings[1];
                }

                else if (reg_pdflatex_error.match (line))
                {
                    string[] strings = reg_pdflatex_error.split (line);
                    tmp = strings[1];
                }

                else if (reg_tex_error.match (line))
                {
                    string[] strings = reg_tex_error.split (line);
                    tmp = strings[1];
                }
                else
                    found = false;

                if (found)
                {
                    nb_lines++;
                    msg.message_type = BuildMessageType.ERROR;

                    // the message is complete
                    if (line[line.length - 1] == '.')
                    {
                        msg.message = tmp;
                        status = FilterStatus.ERROR_SEARCH_LINE;
                    }
                    // the message is splitted
                    else
                    {
                        line_buf = tmp;
                        status = FilterStatus.ERROR;
                    }
                    return true;
                }

                return false;

            case FilterStatus.ERROR:
                line_buf += line;
                nb_lines++;

                if (line[line.length - 1] == '.')
                {
                    msg.message = line_buf;
                    status = FilterStatus.ERROR_SEARCH_LINE;
                }
                else if (nb_lines > 4)
                {
                    msg.message = line_buf;
                    msg.start_line = NO_LINE;
                    add_msg ();
                    nb_lines = 0;
                    status = FilterStatus.START;
                }

                // the return value is not important here
                return true;

            case FilterStatus.ERROR_SEARCH_LINE:
                nb_lines++;
                if (reg_error_line.match (line))
                {
                    string[] strings = reg_error_line.split (line);
                    msg.start_line = int.parse (strings[1]);
                    add_msg ();
                    nb_lines = 0;
                    status = FilterStatus.START;
                    return true;
                }
                else if (nb_lines > 11)
                {
                    msg.start_line = NO_LINE;
                    add_msg ();
                    nb_lines = 0;
                    status = FilterStatus.START;
                    return true;
                }
                break;

            default:
                break;
        }

        return false;
    }

    private bool detect_other (string line)
    {
        if (! line.contains ("Output written on"))
            return false;

        msg.start_line = NO_LINE;
        msg.message_type = BuildMessageType.OTHER;

        if (! reg_other_bytes.match (line))
        {
            msg.message = line;
            add_msg (false);
            return true;
        }

        /* try to show the file size in a human readable format */
        string[] strings = reg_other_bytes.split (line);
        int nb_bytes = int.parse (strings[1]);

        bool replace = false;
        string human_size = null;

        // do nothing
        if (nb_bytes < 1024)
            msg.message = line;

        // size in KB (less than 1 MB)
        else if (nb_bytes < 1024 * 1024)
        {
            int nb_kb = nb_bytes / 1024;
            human_size = "%d KB".printf (nb_kb);
            replace = true;
        }

        // size in MB (with one decimal)
        else
        {
            double nb_mb = (double) nb_bytes / (1024.0 * 1024.0);
            human_size = "%.1f MB".printf (nb_mb);
            replace = true;
        }

        if (replace)
        {
            try
            {
                string new_line =
                    reg_other_bytes.replace_literal (line, -1, 0, human_size);
                msg.message = new_line;
            }

            // nice try!
            catch (RegexError e)
            {
                msg.message = line;
            }
        }

        add_msg (false);
        return true;
    }

    // There are basically two ways to detect the current file TeX is processing:
    // 1) Use \Input (srctex or srcltx package) and \include exclusively. This will
    //    cause (La)TeX to print the line ":<+ filename" in the log file when opening
    //    a file, ":<-" when closing a file. Filenames pushed on the stack in this mode
    //    are marked as reliable.
    //
    // 2) Since people will probably also use the \input command, we also have to be
    //    to detect the old-fashioned way. TeX prints '(filename' when opening a file
    //    and a ')' when closing one. It is impossible to detect this with 100% certainty
    //    (TeX prints many messages and even text (a context) from the TeX source file,
    //    there could be unbalanced parentheses), so we use an heuristic algorithm.
    //    In heuristic mode a ')' will only be considered as a signal that TeX is closing
    //    a file if the top of the stack is not marked as "reliable".
    //
    // The method used here is almost the same as in Kile.

    private void update_stack_file (string line)
    {
        switch (status)
        {
            case FilterStatus.START:
            case FilterStatus.FILENAME_HEURISTIC:
                // TeX is opening a file
                if (line.has_prefix (":<+ "))
                {
                    filename_buf = line.substring (4).strip ();
                    status = FilterStatus.FILENAME;
                }

                // TeX closed a file
                else if (reg_file_pop.match (line) || line.has_prefix (":<-"))
                    pop_file_from_stack ();

                // fallback to the heuristic detection of filenames
                else
                    update_stack_file_heuristic (line);
                break;

            case FilterStatus.FILENAME:
                // The partial filename was followed by '(', this means that TeX is
                // signalling it is opening the file. We are sure the filename is
                // complete now. Don't call update_stack_file_heuristic()
                // since we don't want the filename on the stack twice.
                if (line[0] == '(' || line.has_prefix ("\\openout"))
                {
                    push_file_on_stack (filename_buf, true);
                    status = FilterStatus.START;
                }

                // The partial filename was followed by a TeX error, meaning the
                // file doesn't exist. Don't push it on the stack, instead try to
                // detect the error.
                else if (line[0] == '!')
                {
                    status = FilterStatus.START;
                    detect_error (line);
                }
                else if (line.has_prefix ("No file"))
                {
                    status = FilterStatus.START;
                    detect_warning (line);
                }

                // the filename is not complete
                else
                    filename_buf += line.strip ();
                break;

            default:
                break;
        }
    }

    private void update_stack_file_heuristic (string line)
    {
        bool expect_filename = status == FilterStatus.FILENAME_HEURISTIC;
        int index = 0;
        long length = line.length;

        // handle special case
        if (expect_filename && length > 0 && line[0] == ')')
        {
            push_file_on_stack (filename_buf, false);
            expect_filename = false;
            status = FilterStatus.START;
        }

        // scan for parentheses and grab filenames
        for (int i = 0 ; i < length ; i++)
        {
            /*
            We're expecting a filename. If a filename really ends at this position,
            one of the following must be true:
                1) Next character is a space, indicating the end of a filename
                  (yes, the path can't have spaces, this is a TeX limitation).
                2) We're at the end of the line, the filename is probably
                   continued on the next line.
                3) The file was closed already, signalled by the ')'.
            */

            bool is_last_char = false;
            bool next_is_terminator = false;

            if (expect_filename)
            {
                is_last_char = i + 1 == length;
                next_is_terminator =
                    is_last_char ? false : (line[i+1].isspace () || line[i+1] == ')');
            }

            if (is_last_char || next_is_terminator)
            {
                filename_buf += line[index : i + 1];

                if (filename_buf.length == 0)
                    continue;

                // by default, an output line is 79 characters max
                if ((is_last_char && i < 78)
                    || next_is_terminator
                    || file_exists (filename_buf))
                {
                    push_file_on_stack (filename_buf, false);
                    expect_filename = false;
                    status = FilterStatus.START;
                }

                // Guess the filename is continued on the next line, only if the
                // current filename does not exist
                else if (is_last_char)
                {
                    if (file_exists (filename_buf))
                    {
                        push_file_on_stack (filename_buf, false);
                        expect_filename = false;
                        status = FilterStatus.START;
                    }
                    else
                        status = FilterStatus.FILENAME_HEURISTIC;
                }

                // filename not detected
                else
                {
                    status = FilterStatus.START;
                    filename_buf = "";
                    expect_filename = false;
                }
            }

            // TeX is opening a file
            else if (line[i] == '(')
            {
                status = FilterStatus.START;
                filename_buf = "";
                // we need to extract the filename
                expect_filename = true;
                // this is where the filename is supposed to start
                index = i + 1;
            }

            // TeX is closing a file
            // If this filename was pushed on the stack by the reliable ":<+-"
            // method, don't pop, a ":<-" will follow. This helps in preventing
            // unbalanced ')' from popping filenames from the stack too soon.
            else if (line[i] == ')' && stack_files.length () > 0
                    && ! top_file_on_stack_is_reliable ())
                pop_file_from_stack ();
        }
    }

    private bool
    file_exists (string filename)
    {
        return get_path_if_file_exists (filename) != null;
    }

    // return null if the filename does not exist
    // return the path of the filename if it exists
    private string? get_path_if_file_exists (string filename)
    {
        if (Path.is_absolute (filename))
        {
            if (FileUtils.test (filename, FileTest.IS_REGULAR))
                return filename;
            else
                return null;
        }

        string full_path;
        if (filename.has_prefix ("./"))
            full_path = Path.build_filename (directory_path, filename.substring (2),
                null);
        else
            full_path = Path.build_filename (directory_path, filename, null);

        if (FileUtils.test (full_path, FileTest.IS_REGULAR))
            return full_path;

        // try to add various extensions on the filename to see if the file exists
        string[] extensions = {".tex", ".ltx", ".latex", ".dtx", ".ins"};
        foreach (string ext in extensions)
        {
            string tmp = full_path + ext;
            if (FileUtils.test (tmp, FileTest.IS_REGULAR))
                return tmp;
        }

        return null;
    }

    private string? get_current_filename ()
    {
        if (stack_files == null)
            return null;

        FileInStack file = stack_files.data;
        return file.filename;
    }

    private void push_file_on_stack (string filename, bool reliable)
    {
        FileInStack file = FileInStack ();
        file.reliable = reliable;

        // handle special case when a warning message is collapsed
        string clean_filename;
        string bad_suffix = "pdfTeX";
        if (filename.has_suffix (bad_suffix))
            clean_filename = filename[0 : -bad_suffix.length];
        else
            clean_filename = filename;

        string path = get_path_if_file_exists (clean_filename);
        if (path != null)
            file.filename = path;
        else
            file.filename = clean_filename;

        stack_files.prepend (file);
    }

    private void pop_file_from_stack ()
    {
        if (stack_files == null)
            return;

        stack_files.remove (stack_files.data);
    }

    private bool top_file_on_stack_is_reliable ()
    {
        return_val_if_fail (stack_files != null, true);
        return stack_files.data.reliable;
    }

    private void add_msg (bool set_filename = true)
    {
        // exclude some useless messages here
        if (msg.message_type == BuildMessageType.WARNING
            && msg.message == "There were undefined references.")
        {
            reset_msg ();
            return;
        }

        if (set_filename)
            msg.filename = get_current_filename ();

        try
        {
            // A message on several lines are sometimes indented, so when the lines are
            // catenated there are a lot of spaces. We replace these spaces by one space.
            msg.message = reg_spaces.replace (msg.message, -1, 0, " ");
        }
        catch (RegexError e)
        {
            stderr.printf ("Latex post processor warning: %s\n", e.message);
        }

        switch (msg.message_type)
        {
            case BuildMessageType.BADBOX:
                nb_badboxes++;
                break;

            case BuildMessageType.WARNING:
                nb_warnings++;
                break;

            case BuildMessageType.ERROR:
                nb_errors++;
                break;
        }

        issues.add (msg);
        reset_msg ();
    }

    private void reset_msg ()
    {
        msg = BuildIssue ();
        msg.message = null;
        msg.message_type = BuildMessageType.OTHER;
        msg.filename = null;
        msg.start_line = NO_LINE;
        msg.end_line = NO_LINE;
    }
}
