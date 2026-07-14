classdef oasis_explorer < handle
    % oasis_explorer  Interactive GUI for loading suite2p/CNMF imaging results,
    % running OASIS (deconvolveCa) deconvolution with user-defined
    % parameters on a chosen subset of cells/frames, and visualizing the
    % fit quality (C_raw vs. fitted C, inferred spikes S, and residuals)
    % to help pick good deconvolution settings.
    %
    % Expects a MAT-file (v7.3) named updated_imaging.mat containing a
    % 1x1 struct "results" with fields C_raw, C, S, SNR_gui, GUI, A, Cn,
    % Mn, settings (fs, tau, d1, d2, pipeline, ops), raw (unfiltered
    % cells). Only results.C_raw / C / S / SNR_gui / settings.fs are used
    % here (the "good cells" subset), read directly from the HDF5-backed
    % MAT-file with partial reads so the whole file never has to be
    % loaded into memory.

    properties (Access = private)
        Fig
        CodeFolder char = ''

        % ---- data / file state -------------------------------------
        FilePath char = ''
        Fs double = NaN
        NumCells double = 0
        NumFrames double = 0
        SNRgui double = []

        % ---- UI: data panel ------------------------------------------
        LoadButton
        FileLabel
        DataInfoLabel

        % ---- UI: selection panel --------------------------------------
        CellRangeEdit
        FrameStartEdit
        FrameEndEdit
        AllFramesCheck

        % ---- UI: OASIS parameter panel ---------------------------------
        TypeLabel
        TypeDropdown
        MethodLabel
        MethodDropdown
        ParsEdit
        SnEdit
        LambdaEdit
        SminEdit
        MaxIterSpinner
        WindowEdit
        ShiftEdit
        ThreshFactorEdit
        OptimizeBCheck
        OptimizeParsCheck

        StartButton
        StatusLabel

        % ---- UI: navigator / plots --------------------------------------
        NavDropdown
        PrevButton
        NextButton
        ShowExistingCheck
        ExportButton

        AxRaw
        AxResidual
        MetricsArea

        % ---- results storage -------------------------------------------
        Results = struct('cellIdx', {}, 'frameStart', {}, 'frameEnd', {}, ...
            'y', {}, 'c', {}, 's', {}, 'options', {}, ...
            'yExisting', {}, 'cExisting', {}, 'sExisting', {})
        CurrentIdx double = 0
    end

    methods
        function app = oasis_explorer()
            thisFile = mfilename('fullpath');
            guiFolder = fileparts(thisFile);
            projectFolder = fileparts(guiFolder);
            app.CodeFolder = fullfile(projectFolder, 'code', 'OASIS_matlab-master');

            setupScript = fullfile(app.CodeFolder, 'oasis_setup.m');
            if isfile(setupScript)
                run(setupScript);
            else
                warning('oasis_explorer:setup', 'Could not find oasis_setup.m at %s', setupScript);
            end

            app.buildUI();
        end

        %% ================================================================
        %  UI construction
        %  ================================================================
        function buildUI(app)
            % movegui('center') is unreliable for uifigure (it's designed
            % for legacy figure() and can silently no-op depending on
            % timing/platform), so compute the centered position directly
            % from the screen size instead.
            figW = 1400; figH = 853;
            scr = get(groot, 'ScreenSize');
            figX = max(1, round((scr(3) - figW) / 2));
            figY = max(1, round((scr(4) - figH) / 2));

            app.Fig = uifigure('Name', 'OASIS Deconvolution Explorer', ...
                'Position', [figX figY figW figH]);

            root = uigridlayout(app.Fig, [1 2]);
            root.ColumnWidth = {380, '1x'};
            root.RowHeight = {'1x'};
            root.Padding = [8 8 8 8];
            root.ColumnSpacing = 8;

            % -------------------- LEFT: controls --------------------
            left = uigridlayout(root, [4 1]);
            left.RowHeight = {104, 125, '1x', 218};
            left.Padding = [0 0 0 0];
            left.RowSpacing = 8;

            app.buildDataPanel(left);
            app.buildSelectionPanel(left);
            app.buildParamsPanel(left);
            app.buildStartNavPanel(left);

            % -------------------- RIGHT: plots --------------------
            right = uigridlayout(root, [3 1]);
            right.RowHeight = {'3x', '1x', 130};
            right.Padding = [0 0 0 0];
            right.RowSpacing = 4;

            app.AxRaw = uiaxes(right);
            title(app.AxRaw, 'C_{raw} (df/f), fitted C, and inferred spikes S');
            xlabel(app.AxRaw, 'time (s)');
            yyaxis(app.AxRaw, 'left'); ylabel(app.AxRaw, 'df/f');
            yyaxis(app.AxRaw, 'right'); ylabel(app.AxRaw, 'spikes (S)');
            yyaxis(app.AxRaw, 'left');

            app.AxResidual = uiaxes(right);
            title(app.AxResidual, 'Residual (C_{raw} - C)');
            xlabel(app.AxResidual, 'time (s)'); ylabel(app.AxResidual, 'residual');

            linkaxes([app.AxRaw, app.AxResidual], 'x');

            app.MetricsArea = uitextarea(right);
            app.MetricsArea.Editable = 'off';
            app.MetricsArea.FontName = 'Consolas';
            app.MetricsArea.Value = {'Load data, choose settings, and press Start to run OASIS.'};
        end

        function buildDataPanel(app, parent)
            p = uipanel(parent, 'Title', '1. Data');
            g = uigridlayout(p, [3 1]);
            g.RowHeight = {24, 18, 18};
            g.Padding = [6 3 6 3];
            g.RowSpacing = 2;
            app.LoadButton = uibutton(g, 'Text', 'Load updated_imaging.mat...', ...
                'ButtonPushedFcn', @(src, evt) app.onLoadData());
            app.FileLabel = uilabel(g, 'Text', 'No file loaded', 'FontColor', [0.4 0.4 0.4], ...
                'WordWrap', 'on');
            app.DataInfoLabel = uilabel(g, 'Text', '', 'WordWrap', 'on');
        end

        function buildSelectionPanel(app, parent)
            p = uipanel(parent, 'Title', '2. Cells / frames to deconvolve');
            g = uigridlayout(p, [4 2]);
            g.RowHeight = {18, 18, 18, 18};
            g.ColumnWidth = {130, '1x'};
            g.Padding = [6 3 6 3];
            g.RowSpacing = 2;

            uilabel(g, 'Text', 'Cell(s) (e.g. 1 or 1:5,12)');
            app.CellRangeEdit = uieditfield(g, 'text', 'Value', '1');

            uilabel(g, 'Text', 'Start frame');
            app.FrameStartEdit = uieditfield(g, 'numeric', 'Value', 1, 'Limits', [1 Inf], ...
                'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%.0f');

            uilabel(g, 'Text', 'End frame');
            app.FrameEndEdit = uieditfield(g, 'numeric', 'Value', 2000, 'Limits', [1 Inf], ...
                'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%.0f');

            uilabel(g, 'Text', 'Use all frames');
            app.AllFramesCheck = uicheckbox(g, 'Text', '', 'Value', false, ...
                'ValueChangedFcn', @(src, evt) app.onAllFramesToggled());
        end

        function buildParamsPanel(app, parent)
            % Descriptions paraphrased from deconvolveCa.m's own header
            % comments and the OASIS_matlab README/FOOPSI.md (e.g. the
            % README's own example uses 'smin', -3 as its recommended
            % default: 3x the noise level).
            p = uipanel(parent, 'Title', '3. OASIS / deconvolveCa parameters', 'Scrollable', 'on');
            g = uigridlayout(p, [12 3]);
            g.RowHeight = repmat({20}, 1, 12);
            g.ColumnWidth = {118, 44, '1x'};
            g.Padding = [8 8 8 8];
            g.RowSpacing = 6;

            r = 1;
            app.TypeLabel = uilabel(g, 'Text', 'Kernel type (ar1)');
            app.TypeLabel.Layout.Row = r; app.TypeLabel.Layout.Column = [1 2];
            app.TypeDropdown = uidropdown(g, 'Items', {'ar1', 'ar2', 'exp2'}, 'Value', 'ar1', ...
                'ValueChangedFcn', @(src, evt) app.onTypeChanged());
            app.TypeDropdown.Layout.Row = r; app.TypeDropdown.Layout.Column = 3;

            r = 2;
            app.MethodLabel = uilabel(g, 'Text', 'Method (foopsi)');
            app.MethodLabel.Layout.Row = r; app.MethodLabel.Layout.Column = [1 2];
            app.MethodDropdown = uidropdown(g, 'Items', {'constrained', 'foopsi', 'thresholded'}, 'Value', 'constrained');
            app.MethodDropdown.Layout.Row = r; app.MethodDropdown.Layout.Column = 3;

            r = 3;
            app.ParsEdit = app.addParamRow(g, r, 'pars', 'text', '', ...
                'kernel params. Blank = auto-estimate.');

            r = 4;
            app.SnEdit = app.addParamRow(g, r, 'sn', 'text', '', ...
                'noise std. Blank = auto-estimate.');

            r = 5;
            app.LambdaEdit = app.addParamRow(g, r, 'lambda', 'numeric', 0, ...
                'L1 penalty on spikes. Default 0.');

            r = 6;
            app.SminEdit = app.addParamRow(g, r, 'smin', 'numeric', -3, ...
                'spike threshold; neg = x*sn. Default -3.');

            r = 7;
            lbl = uilabel(g, 'Text', 'maxIter'); lbl.Layout.Row = r; lbl.Layout.Column = 1;
            app.MaxIterSpinner = uispinner(g, 'Value', 10, 'Limits', [1 1000], 'RoundFractionalValues', 'on');
            app.MaxIterSpinner.Layout.Row = r; app.MaxIterSpinner.Layout.Column = 2;
            help = uilabel(g, 'Text', 'max iterations. Default 10.', ...
                'WordWrap', 'off', 'FontColor', [0.45 0.45 0.45], 'FontSize', 10);
            help.Layout.Row = r; help.Layout.Column = 3;

            r = 8;
            app.WindowEdit = app.addParamRow(g, r, 'window', 'numeric', 200, ...
                'kernel length (exp2). Default 200.');

            r = 9;
            app.ShiftEdit = app.addParamRow(g, r, 'shift', 'numeric', 100, ...
                'NNLS window shift (exp2). Default 100.');

            r = 10;
            app.ThreshFactorEdit = app.addParamRow(g, r, 'thresh_factor', 'numeric', 1.0, ...
                'scales smin (thresholded). Default 1.0.');

            r = 11;
            lbl = uilabel(g, 'Text', 'optimize_b'); lbl.Layout.Row = r; lbl.Layout.Column = 1;
            app.OptimizeBCheck = uicheckbox(g, 'Text', '', 'Value', false);
            app.OptimizeBCheck.Layout.Row = r; app.OptimizeBCheck.Layout.Column = 2;
            help = uilabel(g, 'Text', 'auto-estimate baseline b. Default off.', ...
                'WordWrap', 'off', 'FontColor', [0.45 0.45 0.45], 'FontSize', 10);
            help.Layout.Row = r; help.Layout.Column = 3;

            r = 12;
            lbl = uilabel(g, 'Text', 'optimize_pars'); lbl.Layout.Row = r; lbl.Layout.Column = 1;
            app.OptimizeParsCheck = uicheckbox(g, 'Text', '', 'Value', false);
            app.OptimizeParsCheck.Layout.Row = r; app.OptimizeParsCheck.Layout.Column = 2;
            help = uilabel(g, 'Text', 'auto-estimate AR params. Default off.', ...
                'WordWrap', 'off', 'FontColor', [0.45 0.45 0.45], 'FontSize', 10);
            help.Layout.Row = r; help.Layout.Column = 3;
        end

        function fld = addParamRow(~, g, r, labelText, editType, defaultVal, helpText)
            lbl = uilabel(g, 'Text', labelText); lbl.Layout.Row = r; lbl.Layout.Column = 1;
            fld = uieditfield(g, editType, 'Value', defaultVal);
            fld.Layout.Row = r; fld.Layout.Column = 2;
            help = uilabel(g, 'Text', helpText, 'WordWrap', 'off', 'FontColor', [0.45 0.45 0.45], 'FontSize', 10);
            help.Layout.Row = r; help.Layout.Column = 3;
        end

        function buildStartNavPanel(app, parent)
            % Keeps the Run button visually tight against the results
            % navigator right below it (its own small RowSpacing),
            % separate from the looser spacing above.
            g = uigridlayout(parent, [2 1]);
            g.RowHeight = {52, '1x'};
            g.Padding = [0 0 0 0];
            g.RowSpacing = 2;
            app.buildStartPanel(g);
            app.buildNavPanel(g);
        end

        function buildStartPanel(app, parent)
            g = uigridlayout(parent, [2 1]);
            g.RowHeight = {32, 18};
            g.Padding = [0 0 0 0];
            g.RowSpacing = 1;
            app.StartButton = uibutton(g, 'Text', 'Run OASIS', 'FontWeight', 'bold', ...
                'BackgroundColor', [0.2 0.6 0.3], 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(src, evt) app.onStart());
            app.StatusLabel = uilabel(g, 'Text', '', 'FontColor', [0.4 0.4 0.4]);
        end

        function buildNavPanel(app, parent)
            p = uipanel(parent, 'Title', '4. Results navigator');
            g = uigridlayout(p, [4 2]);
            g.RowHeight = {26, 27, 27, 27};
            g.ColumnWidth = {'1x', '1x'};
            g.Padding = [8 6 8 6];
            g.RowSpacing = 5;

            app.PrevButton = uibutton(g, 'Text', '<< Prev', 'ButtonPushedFcn', @(src, evt) app.onPrev());
            app.NextButton = uibutton(g, 'Text', 'Next >>', 'ButtonPushedFcn', @(src, evt) app.onNext());

            app.NavDropdown = uidropdown(g, 'Items', {'(no results yet)'}, ...
                'ValueChangedFcn', @(src, evt) app.onNavChanged());
            app.NavDropdown.Layout.Column = [1 2];

            app.ShowExistingCheck = uicheckbox(g, 'Text', 'Show existing C/S from file', 'Value', false, ...
                'ValueChangedFcn', @(src, evt) app.updatePlot());
            app.ShowExistingCheck.Layout.Column = [1 2];

            app.ExportButton = uibutton(g, 'Text', 'Export results...', 'ButtonPushedFcn', @(src, evt) app.onExport());
            app.ExportButton.Layout.Column = [1 2];
        end

        %% ================================================================
        %  Callbacks
        %  ================================================================
        function onLoadData(app)
            % Start the dialog in whatever folder was loaded last time
            % (falls back to the project's data/ folder on first use),
            % so that once a file has been picked, opening the dialog
            % again lands right back in that same folder.
            if ~isempty(app.FilePath) && isfolder(fileparts(app.FilePath))
                startFolder = fileparts(app.FilePath);
            else
                startFolder = fullfile(fileparts(app.CodeFolder), 'data');
                if ~isfolder(startFolder)
                    startFolder = fileparts(app.CodeFolder);
                end
            end
            [f, p] = uigetfile('*.mat', 'Select updated_imaging.mat', ...
                fullfile(startFolder, 'updated_imaging.mat'));
            if isequal(f, 0)
                return;
            end
            fp = fullfile(p, f);

            try
                info = h5info(fp, '/results/C_raw');
            catch ME
                uialert(app.Fig, sprintf('Could not read %s as an HDF5/v7.3 MAT-file with a results.C_raw field.\n%s', fp, ME.message), 'Load error');
                return;
            end

            try
                cd(p); % convenience: work from the data's folder from now on
            catch
                % non-fatal if the folder can't be made current
            end

            isFirstLoad = isempty(app.FilePath);

            app.FilePath = fp;
            sz = info.Dataspace.Size;
            app.NumCells = sz(1);
            app.NumFrames = sz(2);
            app.Fs = h5read(fp, '/results/settings/fs');
            app.SNRgui = h5read(fp, '/results/SNR_gui');

            app.FileLabel.Text = f;
            app.DataInfoLabel.Text = sprintf('%d cells x %d frames, fs = %.3g Hz', ...
                app.NumCells, app.NumFrames, app.Fs);

            app.FrameStartEdit.Limits = [1 app.NumFrames];
            app.FrameEndEdit.Limits = [1 app.NumFrames];
            if isFirstLoad
                % First file loaded this session: seed sensible defaults.
                app.FrameStartEdit.Value = 1;
                app.FrameEndEdit.Value = min(2000, app.NumFrames);
                app.CellRangeEdit.Value = '1';
            else
                % Loading a different file later: keep whatever the user
                % had set for cells/frames, just clamp to the new file's
                % valid range so it can't point past the end of the data.
                app.FrameStartEdit.Value = min(max(app.FrameStartEdit.Value, 1), app.NumFrames);
                app.FrameEndEdit.Value = min(max(app.FrameEndEdit.Value, 1), app.NumFrames);
                if app.FrameEndEdit.Value <= app.FrameStartEdit.Value
                    app.FrameEndEdit.Value = min(app.FrameStartEdit.Value + 1, app.NumFrames);
                end
            end

            % reset previous results
            app.Results(:) = [];
            app.CurrentIdx = 0;
            app.NavDropdown.Items = {'(no results yet)'};
            app.NavDropdown.Value = '(no results yet)';
            yyaxis(app.AxRaw, 'left'); cla(app.AxRaw);
            yyaxis(app.AxRaw, 'right'); cla(app.AxRaw);
            yyaxis(app.AxRaw, 'left');
            cla(app.AxResidual);
            app.MetricsArea.Value = {'Data loaded. Choose cells/frames and parameters, then press Start.'};
            app.StatusLabel.Text = '';
        end

        function onAllFramesToggled(app)
            useAll = app.AllFramesCheck.Value;
            app.FrameStartEdit.Enable = ~useAll;
            app.FrameEndEdit.Enable = ~useAll;
        end

        function onTypeChanged(app)
            % 'constrained' only has a pure-MATLAB implementation for
            % ar1 in this OASIS release; for ar2/exp2 it falls through
            % to a CVX-based solver that isn't installed and errors out.
            % Restrict the Method list per type so that never happens.
            switch app.TypeDropdown.Value
                case 'ar1'
                    validMethods = {'constrained', 'foopsi', 'thresholded'};
                case 'ar2'
                    validMethods = {'foopsi', 'thresholded'};
                case 'exp2'
                    validMethods = {'foopsi'};
                otherwise
                    validMethods = {'foopsi'};
            end
            currentValue = app.MethodDropdown.Value;
            app.MethodDropdown.Items = validMethods;
            if ismember(currentValue, validMethods)
                app.MethodDropdown.Value = currentValue;
            else
                app.MethodDropdown.Value = validMethods{1};
            end
            % Note: TypeLabel/MethodLabel intentionally stay fixed at
            % "Kernel type (ar1)" / "Method (foopsi)" as a permanent
            % reminder of the defaults, regardless of what's selected.
        end

        function onMethodChanged(app)
            app.MethodLabel.Text = sprintf('Method (%s)', app.MethodDropdown.Value);
        end

        function onStart(app)
            if isempty(app.FilePath)
                uialert(app.Fig, 'Load updated_imaging.mat first.', 'No data');
                return;
            end

            cellList = app.parseIndexList(app.CellRangeEdit.Value, app.NumCells);
            if isempty(cellList)
                uialert(app.Fig, 'Could not parse the cell list. Use e.g. "3" or "1:5,12".', 'Invalid input');
                return;
            end

            if app.AllFramesCheck.Value
                frameStart = 1;
                frameEnd = app.NumFrames;
            else
                frameStart = round(app.FrameStartEdit.Value);
                frameEnd = round(app.FrameEndEdit.Value);
            end
            if frameEnd <= frameStart || frameStart < 1 || frameEnd > app.NumFrames
                uialert(app.Fig, 'Invalid frame range.', 'Invalid input');
                return;
            end
            nFrames = frameEnd - frameStart + 1;

            oasisArgs = app.buildOasisArgs();

            d = uiprogressdlg(app.Fig, 'Title', 'Running OASIS', ...
                'Message', 'Starting...', 'Cancelable', 'on');
            cleanupObj = onCleanup(@() close(d));

            firstNewIdx = [];
            for k = 1:numel(cellList)
                if d.CancelRequested
                    break;
                end
                cIdx = cellList(k);
                d.Value = k / numel(cellList);
                d.Message = sprintf('Cell %d (%d/%d)...', cIdx, k, numel(cellList));

                y = h5read(app.FilePath, '/results/C_raw', [cIdx frameStart], [1 nFrames]);
                y = double(y(:));

                try
                    [c, s, opts] = deconvolveCa(y, oasisArgs{:});
                catch ME
                    uialert(app.Fig, sprintf('deconvolveCa failed on cell %d: %s', cIdx, ME.message), 'Run error');
                    continue;
                end

                yExisting = double(h5read(app.FilePath, '/results/C_raw', [cIdx frameStart], [1 nFrames]));
                cExisting = double(h5read(app.FilePath, '/results/C', [cIdx frameStart], [1 nFrames]));
                sExisting = double(h5read(app.FilePath, '/results/S', [cIdx frameStart], [1 nFrames]));

                entry = struct('cellIdx', cIdx, 'frameStart', frameStart, 'frameEnd', frameEnd, ...
                    'y', y, 'c', c, 's', s, 'options', opts, ...
                    'yExisting', yExisting(:), 'cExisting', cExisting(:), 'sExisting', sExisting(:));

                existingMatch = find([app.Results.cellIdx] == cIdx & ...
                    [app.Results.frameStart] == frameStart & [app.Results.frameEnd] == frameEnd, 1);
                if ~isempty(existingMatch)
                    app.Results(existingMatch) = entry;
                    if isempty(firstNewIdx); firstNewIdx = existingMatch; end
                else
                    app.Results(end + 1) = entry;
                    if isempty(firstNewIdx); firstNewIdx = numel(app.Results); end
                end
            end

            app.refreshNavDropdown();
            if ~isempty(firstNewIdx)
                app.CurrentIdx = firstNewIdx;
                app.NavDropdown.Value = app.NavDropdown.Items{firstNewIdx};
                app.updatePlot();
            end
            app.StatusLabel.Text = sprintf('Done. %d result(s) stored.', numel(app.Results));
        end

        function onPrev(app)
            if isempty(app.Results); return; end
            app.CurrentIdx = max(1, app.CurrentIdx - 1);
            app.NavDropdown.Value = app.NavDropdown.Items{app.CurrentIdx};
            app.updatePlot();
        end

        function onNext(app)
            if isempty(app.Results); return; end
            app.CurrentIdx = min(numel(app.Results), app.CurrentIdx + 1);
            app.NavDropdown.Value = app.NavDropdown.Items{app.CurrentIdx};
            app.updatePlot();
        end

        function onNavChanged(app)
            idx = find(strcmp(app.NavDropdown.Items, app.NavDropdown.Value), 1);
            if ~isempty(idx)
                app.CurrentIdx = idx;
                app.updatePlot();
            end
        end

        function onExport(app)
            if isempty(app.Results)
                uialert(app.Fig, 'No results to export yet.', 'Nothing to export');
                return;
            end
            [f, p] = uiputfile('*.mat', 'Save OASIS results', 'oasis_explorer_results.mat');
            if isequal(f, 0); return; end
            oasis_results = app.Results; %#ok<NASGU>
            source_file = app.FilePath; %#ok<NASGU>
            save(fullfile(p, f), 'oasis_results', 'source_file', '-v7.3');
            app.StatusLabel.Text = sprintf('Exported to %s', f);
        end

        %% ================================================================
        %  Plotting
        %  ================================================================
        function updatePlot(app)
            if app.CurrentIdx < 1 || app.CurrentIdx > numel(app.Results)
                return;
            end
            r = app.Results(app.CurrentIdx);
            t = (0:numel(r.y) - 1) / app.Fs;
            showExisting = app.ShowExistingCheck.Value;

            % ---- combined: raw + fitted C (+ existing C) on the left
            % y-axis, spikes S on their own right y-axis (true 0
            % baseline, independent of the C traces' scale/offset so it
            % never drifts when C_raw's baseline isn't near zero and
            % never jumps when toggling the existing-pipeline overlay).
            % cla() only clears whichever yyaxis side is currently
            % active, so the right-hand (S) side was never actually
            % cleared between renders and kept accumulating stems/legend
            % entries. Clear both sides explicitly.
            yyaxis(app.AxRaw, 'left'); cla(app.AxRaw);
            yyaxis(app.AxRaw, 'right'); cla(app.AxRaw);

            grayCol = [0.55 0.55 0.55];
            orangeCol = [0.90 0.55 0.10];
            greenCol = [0.20 0.60 0.20];

            % "Show existing C/S from file" is a toggle, not an overlay:
            % on = show only the existing file's C/S, off = show only
            % this run's new fit. They replace each other rather than
            % stacking, to keep the plot readable. Both are solid lines
            % (dotted was hard to follow) - color alone distinguishes
            % raw/fit/spikes, and the legend/checkbox state distinguishes
            % new fit vs. existing file.
            yyaxis(app.AxRaw, 'left'); hold(app.AxRaw, 'on');
            plot(app.AxRaw, t, r.y, 'Color', grayCol, 'LineWidth', 0.75, 'DisplayName', 'C_{raw}');
            if showExisting
                plot(app.AxRaw, t, r.cExisting, 'LineStyle', '-', 'Color', orangeCol, 'LineWidth', 1.3, 'DisplayName', 'C existing (from file)');
            else
                plot(app.AxRaw, t, r.c, 'LineStyle', '-', 'Color', orangeCol, 'LineWidth', 1.3, 'DisplayName', 'C fitted');
            end
            app.AxRaw.YColor = [0.15 0.15 0.15];
            hold(app.AxRaw, 'off');

            yyaxis(app.AxRaw, 'right'); hold(app.AxRaw, 'on');
            if showExisting
                stem(app.AxRaw, t, r.sExisting(:), 'Color', greenCol, 'LineStyle', '-', ...
                    'Marker', 'none', 'LineWidth', 1.0, 'DisplayName', 'S existing (from file)');
            else
                stem(app.AxRaw, t, r.s(:), 'Color', greenCol, 'LineStyle', '-', ...
                    'Marker', 'none', 'LineWidth', 1.0, 'DisplayName', 'S fitted');
            end
            app.AxRaw.YColor = greenCol;
            sMax = max([r.s(:); r.sExisting(:); 1]);
            ylim(app.AxRaw, [0, sMax * 1.15]);
            hold(app.AxRaw, 'off');

            yyaxis(app.AxRaw, 'left');
            legend(app.AxRaw, 'Location', 'northoutside', 'Orientation', 'horizontal');
            title(app.AxRaw, sprintf('Cell %d — frames %d-%d', r.cellIdx, r.frameStart, r.frameEnd));
            xlim(app.AxRaw, [t(1) t(end)]);

            % ---- bottom: residual ----
            resid = r.y - r.c;
            cla(app.AxResidual); hold(app.AxResidual, 'on');
            plot(app.AxResidual, t, resid, 'Color', [0.3 0.3 0.75], 'LineWidth', 0.6);
            sn = app.getOpt(r.options, 'sn', NaN);
            if isfinite(sn)
                yline(app.AxResidual, sn, ':', 'Color', [0.5 0.5 0.5], 'DisplayName', '+sn');
                yline(app.AxResidual, -sn, ':', 'Color', [0.5 0.5 0.5], 'DisplayName', '-sn');
            end
            yline(app.AxResidual, 0, '-', 'Color', [0.8 0.8 0.8]);
            hold(app.AxResidual, 'off');
            xlim(app.AxResidual, [t(1) t(end)]);

            app.updateMetrics(r);
        end

        function updateMetrics(app, r)
            fs = app.Fs;
            durSec = numel(r.y) / fs;

            resid = r.y - r.c;
            residStd = std(resid);
            snUsed = app.getOpt(r.options, 'sn', NaN);
            lambdaUsed = app.getOpt(r.options, 'lambda', NaN);
            parsUsed = app.getOpt(r.options, 'pars', []);

            varExplained = 1 - var(resid) / var(r.y);
            cc = corrcoef(r.y, r.c);
            corrNew = cc(1, 2);

            nEventsNew = nnz(r.s > 0);
            rateNew = nEventsNew / durSec;

            nEventsExisting = nnz(r.sExisting > 0);
            rateExisting = nEventsExisting / durSec;
            residExisting = r.yExisting - r.cExisting;
            varExplainedExisting = 1 - var(residExisting) / var(r.yExisting);
            ccE = corrcoef(r.yExisting, r.cExisting);
            corrExisting = ccE(1, 2);

            snrRef = NaN;
            if r.cellIdx <= numel(app.SNRgui)
                snrRef = app.SNRgui(r.cellIdx);
            end

            parsStr = mat2str(parsUsed(:)', 4);

            lines = {
                sprintf('Cell %d  |  frames %d-%d (%.1f s)  |  fs = %.3g Hz  |  reference SNR_gui = %.3g', ...
                    r.cellIdx, r.frameStart, r.frameEnd, durSec, fs, snrRef)
                sprintf('type=%s  method=%s  pars=%s  sn(used)=%.4g  lambda(used)=%.4g', ...
                    app.getOpt(r.options, 'type', '?'), app.getOpt(r.options, 'method', '?'), ...
                    parsStr, snUsed, lambdaUsed)
                ''
                sprintf('%-22s %10s %10s', ' ', 'NEW fit', 'existing')
                sprintf('%-22s %10.3g %10.3g', 'variance explained', varExplained, varExplainedExisting)
                sprintf('%-22s %10.3g %10.3g', 'corr(raw, C)', corrNew, corrExisting)
                sprintf('%-22s %10d %10d', '# spikes detected', nEventsNew, nEventsExisting)
                sprintf('%-22s %10.3g %10.3g', 'event rate (Hz)', rateNew, rateExisting)
                sprintf('%-22s %10.3g %10s', 'residual std (new)', residStd, '')
                ''
                'Tip: a good fit has high variance-explained / correlation, residual std close to sn'
                'with no leftover transient shape, and a spike rate that looks biologically plausible.'
                };
            app.MetricsArea.Value = lines;
        end

        %% ================================================================
        %  Helpers
        %  ================================================================
        function args = buildOasisArgs(app)
            type = app.TypeDropdown.Value;
            method = app.MethodDropdown.Value;
            pars = app.parseNumList(app.ParsEdit.Value);
            sn = app.parseNumList(app.SnEdit.Value);
            if numel(sn) > 1
                sn = sn(1);
            end

            args = {type, 'pars', pars, 'sn', sn, 'b', 0, ...
                'optimize_b', logical(app.OptimizeBCheck.Value), ...
                'optimize_pars', logical(app.OptimizeParsCheck.Value), ...
                'lambda', app.LambdaEdit.Value, method, ...
                'window', round(app.WindowEdit.Value), ...
                'shift', round(app.ShiftEdit.Value), ...
                'smin', app.SminEdit.Value, ...
                'maxIter', round(app.MaxIterSpinner.Value), ...
                'thresh_factor', app.ThreshFactorEdit.Value};
        end

        function refreshNavDropdown(app)
            if isempty(app.Results)
                app.NavDropdown.Items = {'(no results yet)'};
                app.NavDropdown.Value = '(no results yet)';
                return;
            end
            items = arrayfun(@(r) sprintf('Cell %d (frames %d-%d)', r.cellIdx, r.frameStart, r.frameEnd), ...
                app.Results, 'UniformOutput', false);
            app.NavDropdown.Items = items;
            if app.CurrentIdx >= 1 && app.CurrentIdx <= numel(items)
                app.NavDropdown.Value = items{app.CurrentIdx};
            else
                app.NavDropdown.Value = items{1};
            end
        end
    end

    methods (Static)
        function idxList = parseIndexList(str, maxVal)
            % Parse strings like "3", "1:5", "1:5,12,20:2:30" into a
            % sorted unique numeric index vector, clipped to [1 maxVal].
            idxList = [];
            str = strtrim(str);
            if isempty(str)
                return;
            end
            if ~isempty(regexp(str, '[^0-9:,\s-]', 'once'))
                return; % reject anything that isn't digits/colon/comma/space/minus
            end
            parts = strsplit(str, ',');
            vals = [];
            try
                for i = 1:numel(parts)
                    piece = strtrim(parts{i});
                    if isempty(piece)
                        continue;
                    end
                    vals = [vals, str2num(piece)]; %#ok<ST2NM,AGROW>
                end
            catch
                idxList = [];
                return;
            end
            vals = round(vals(:)');
            vals = vals(vals >= 1 & vals <= maxVal);
            idxList = unique(vals);
        end

        function v = parseNumList(str)
            % Parse a comma/space-separated list of numbers, or return []
            % for a blank string (meaning "auto" for deconvolveCa).
            str = strtrim(str);
            if isempty(str)
                v = [];
                return;
            end
            str = strrep(str, ',', ' ');
            v = str2num(['[' str ']']); %#ok<ST2NM>
            if isempty(v)
                v = [];
            end
        end

        function v = getOpt(options, field, default)
            if isfield(options, field) && ~isempty(options.(field))
                v = options.(field);
            else
                v = default;
            end
        end
    end
end
