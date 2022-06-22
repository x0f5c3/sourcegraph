package com.sourcegraph.find;

import com.intellij.find.FindBundle;
import com.intellij.find.FindModel;
import com.intellij.find.actions.ShowUsagesAction;
import com.intellij.find.impl.FindInProjectExecutor;
import com.intellij.find.impl.FindInProjectUtil;
import com.intellij.find.impl.FindUI;
import com.intellij.ide.IdeEventQueue;
import com.intellij.ide.scratch.ScratchUtil;
import com.intellij.ide.ui.UISettings;
import com.intellij.openapi.Disposable;
import com.intellij.openapi.actionSystem.ActionManager;
import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.openapi.actionSystem.CommonShortcuts;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.ModalityState;
import com.intellij.openapi.progress.ProgressIndicator;
import com.intellij.openapi.progress.ProgressManager;
import com.intellij.openapi.progress.Task;
import com.intellij.openapi.progress.util.ProgressIndicatorBase;
import com.intellij.openapi.project.DumbAwareAction;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.project.ProjectManagerListener;
import com.intellij.openapi.ui.DialogWrapper;
import com.intellij.openapi.ui.popup.JBPopup;
import com.intellij.openapi.ui.popup.JBPopupFactory;
import com.intellij.openapi.util.*;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.openapi.util.text.StringUtil;
import com.intellij.openapi.vfs.VfsUtilCore;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.openapi.wm.impl.IdeFrameImpl;
import com.intellij.openapi.wm.impl.IdeGlassPaneImpl;
import com.intellij.ui.PopupBorder;
import com.intellij.ui.WindowMoveListener;
import com.intellij.ui.WindowResizeListener;
import com.intellij.ui.awt.RelativePoint;
import com.intellij.ui.components.JBLabel;
import com.intellij.ui.components.JBPanel;
import com.intellij.ui.scale.JBUIScale;
import com.intellij.usages.FindUsagesProcessPresentation;
import com.intellij.usages.UsageViewPresentation;
import com.intellij.util.Alarm;
import com.intellij.util.PathUtil;
import com.intellij.util.SmartList;
import com.intellij.util.containers.ContainerUtil;
import com.intellij.util.ui.JBUI;
import com.intellij.util.ui.UIUtil;
import org.jetbrains.annotations.Contract;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import javax.swing.*;
import javax.swing.border.Border;
import java.awt.*;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class ForkedFindPopupPanel extends JBPanel<ForkedFindPopupPanel> implements FindUI {
    private static final String SERVICE_KEY = "sourcegraph.find.popup";
    @NotNull
    private final Project myProject;
    @NotNull
    private final Disposable myDisposable;
    private final Alarm myPreviewUpdater;
    private ActionListener myOkActionListener;
    private JBLabel myOKHintLabel;
    private JBLabel myNavigationHintLabel;
    private Alarm mySearchRescheduleOnCancellationsAlarm;
    private volatile ProgressIndicatorBase myResultsPreviewSearchProgress;
    private String mySelectedContextName = FindBundle.message("find.context.anywhere.scope.label");

    private DialogWrapper myDialog;
    private int myLoadingHash;
    private final AtomicBoolean myNeedReset = new AtomicBoolean(true);
    private UsageViewPresentation myUsageViewPresentation;
    private boolean mySuggestRegexHintForEmptyResults = true;

    private FindContentPanel findContentPanel;

    ForkedFindPopupPanel(Project project, FindContentPanel findContentPanel) {
        myProject = project;
        this.findContentPanel = findContentPanel;
        myDisposable = Disposer.newDisposable();
        myPreviewUpdater = new Alarm(myDisposable);
//        myScopeUI = FindPopupScopeUIProvider.getInstance().create(this);

        Disposer.register(myDisposable, () -> {
            finishPreviousPreviewSearch();
            if (mySearchRescheduleOnCancellationsAlarm != null)
                Disposer.dispose(mySearchRescheduleOnCancellationsAlarm);
        });

        initComponents();
        initByModel();
    }

    @Override
    public void showUI() {
        if (myDialog != null && myDialog.isVisible()) {
            return;
        }
        if (myDialog != null && !myDialog.isDisposed()) {
            myDialog.doCancelAction();
        }
        if (myDialog == null || myDialog.isDisposed()) {
            myDialog = new DialogWrapper(this.myProject, null, true, DialogWrapper.IdeModalityType.MODELESS, false) {
                {
                    init();
                    getRootPane().setDefaultButton(null);
                }

                @Override
                protected void doOKAction() {
                    myOkActionListener.actionPerformed(null);
                }

                @Override
                protected void dispose() {
                    saveSettings();
                    super.dispose();
                }

                @Nullable
                @Override
                protected Border createContentPaneBorder() {
                    return null;
                }

                @Override
                protected JComponent createCenterPanel() {
                    return ForkedFindPopupPanel.this;
                }

                @Override
                protected String getDimensionServiceKey() {
                    return SERVICE_KEY;
                }
            };
            myDialog.setUndecorated(true);
            ApplicationManager.getApplication().getMessageBus().connect(myDialog.getDisposable()).subscribe(ProjectManager.TOPIC, new ProjectManagerListener() {
                @Override
                public void projectClosed(@NotNull Project project) {
                    closeImmediately();
                }
            });
            Disposer.register(myDialog.getDisposable(), myDisposable);

            Window window = WindowManager.getInstance().suggestParentWindow(myProject);
            Component parent = UIUtil.findUltimateParent(window);
            RelativePoint showPoint = null;
            Point screenPoint = DimensionService.getInstance().getLocation(SERVICE_KEY);
            if (screenPoint != null) {
                if (parent != null) {
                    SwingUtilities.convertPointFromScreen(screenPoint, parent);
                    showPoint = new RelativePoint(parent, screenPoint);
                } else {
                    showPoint = new RelativePoint(screenPoint);
                }
            }
            if (parent != null && showPoint == null) {
                int height = UISettings.getInstance().getShowNavigationBar() ? 135 : 115;
                if (parent instanceof IdeFrameImpl && ((IdeFrameImpl) parent).isInFullScreen()) {
                    height -= 20;
                }
                showPoint = new RelativePoint(parent, new Point((parent.getSize().width - getPreferredSize().width) / 2, height));
            }
            WindowMoveListener windowListener = new WindowMoveListener(this);
            addMouseListener(windowListener);
            addMouseMotionListener(windowListener);
            Dimension panelSize = getPreferredSize();
            Dimension prev = DimensionService.getInstance().getSize(SERVICE_KEY);
            panelSize.width += JBUIScale.scale(24);//hidden 'loading' icon
            panelSize.height *= 2;
            if (prev != null && prev.height < panelSize.height) prev.height = panelSize.height;
            Window dialogWindow = myDialog.getPeer().getWindow();
            AnAction escape = ActionManager.getInstance().getAction("EditorEscape");
            JRootPane root = ((RootPaneContainer) dialogWindow).getRootPane();

            IdeGlassPaneImpl glass = (IdeGlassPaneImpl) myDialog.getRootPane().getGlassPane();
            WindowResizeListener resizeListener = new WindowResizeListener(
                root,
                JBUI.insets(4),
                null) {
                private Cursor myCursor;

                @Override
                protected void setCursor(@NotNull Component content, Cursor cursor) {
                    if (myCursor != cursor || myCursor != Cursor.getDefaultCursor()) {
                        glass.setCursor(cursor, this);
                        myCursor = cursor;

                        if (content instanceof JComponent) {
                            IdeGlassPaneImpl.savePreProcessedCursor((JComponent) content, content.getCursor());
                        }
                        super.setCursor(content, cursor);
                    }
                }
            };
            glass.addMousePreprocessor(resizeListener, myDisposable);
            glass.addMouseMotionPreprocessor(resizeListener, myDisposable);

            DumbAwareAction.create(e -> closeImmediately())
                .registerCustomShortcutSet(escape == null ? CommonShortcuts.ESCAPE : escape.getShortcutSet(), root, myDisposable);
            root.setWindowDecorationStyle(JRootPane.NONE);
            root.setBorder(PopupBorder.Factory.create(true, true));
            UIUtil.markAsPossibleOwner((Dialog) dialogWindow);
            dialogWindow.setBackground(UIUtil.getPanelBackground());
            dialogWindow.setMinimumSize(panelSize);
            if (prev == null) {
                panelSize.height *= 1.5;
                panelSize.width *= 1.15;
            }
            dialogWindow.setSize(prev != null ? prev : panelSize);

            IdeEventQueue.getInstance().getPopupManager().closeAllPopups(false);
            if (showPoint != null) {
                myDialog.setLocation(showPoint.getScreenPoint());
            } else {
                dialogWindow.setLocationRelativeTo(null);
            }
            mySuggestRegexHintForEmptyResults = true;
            myDialog.show();

//            myDialog.setOnDeactivationAction(() -> closeIfPossible());

            JRootPane rootPane = getRootPane();
            if (rootPane != null) {
                rootPane.getActionMap().put("openInFindWindow", new AbstractAction() {
                    @Override
                    public void actionPerformed(ActionEvent e) {
                        myOkActionListener.actionPerformed(null);
                    }
                });
            }
            ApplicationManager.getApplication().invokeLater(this::scheduleResultsUpdate, ModalityState.any());
        }
    }

    public void closeIfPossible() {
        if (canBeClosed()) {
            myDialog.doCancelAction();
        }
    }

    protected boolean canBeClosed() {
        if (myProject.isDisposed()) return true;
        if (!ApplicationManager.getApplication().isActive()) return false;
        if (KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusedWindow() == null) return false;
        List<JBPopup> popups = ContainerUtil.filter(JBPopupFactory.getInstance().getChildPopups(this), popup -> !popup.isDisposed());
        if (!popups.isEmpty()) {
            for (JBPopup popup : popups) {
                popup.cancel();
            }
            return false;
        }
        return true;
    }

    @Override
    public void saveSettings() {
        Window window = myDialog.getWindow();
        if (!window.isShowing()) return;
        DimensionService.getInstance().setSize(SERVICE_KEY, myDialog.getSize(), this.myProject);
        DimensionService.getInstance().setLocation(SERVICE_KEY, window.getLocationOnScreen(), this.myProject);
//        applyTo(FindManager.getInstance(myProject).getFindInProjectModel());
    }

    @NotNull
    @Override
    public Disposable getDisposable() {
        return myDisposable;
    }

    @NotNull
    public Project getProject() {
        return myProject;
    }


    private void initComponents() {
        mySearchRescheduleOnCancellationsAlarm = new Alarm();
//        setLayout(new MigLayout("flowx, ins 0, gap 0, fillx, hidemode 3"));
        add(this.findContentPanel);
    }

    @Contract("_,!null,_->!null")
    static @NlsSafe String getPresentablePath(@NotNull Project project, @Nullable VirtualFile virtualFile, int maxChars) {
        if (virtualFile == null) return null;
        String path = ScratchUtil.isScratch(virtualFile)
            ? ScratchUtil.getRelativePath(project, virtualFile)
            : VfsUtilCore.isAncestor(project.getBaseDir(), virtualFile, true)
            ? VfsUtilCore.getRelativeLocation(virtualFile, project.getBaseDir())
            : FileUtil.getLocationRelativeToUserHome(virtualFile.getPath());
        return path == null ? null : maxChars < 0 ? path : StringUtil.trimMiddle(path, maxChars);
    }


    private void closeImmediately() {
        if (canBeClosedImmediately() && myDialog != null && myDialog.isVisible()) {
            myDialog.doCancelAction();
        }
    }

    //Some popups shown above may prevent panel closing, first of all we should close them
    private boolean canBeClosedImmediately() {
        return myDialog != null && canBeClosed();
    }

    private void doOK(boolean openInFindWindow) {
        if (!canBeClosedImmediately()) {
            return;
        }
        myDialog.doCancelAction();
    }

    @Override
    public void initByModel() {
    }

    private void updateControls() {
//        myReplaceAllButton.setVisible(myHelper.isReplaceState());
//        myReplaceSelectedButton.setVisible(myHelper.isReplaceState());
//        myNavigationHintLabel.setVisible(mySearchComponent.getText().contains("\n"));
//        mySearchTextArea.updateExtraActions();
//        myReplaceTextArea.updateExtraActions();
//        if (myNavigationHintLabel.isVisible()) {
//            myNavigationHintLabel.setText("");
//            KeymapManager keymapManager = KeymapManager.getInstance();
//            Keymap activeKeymap = keymapManager != null ? keymapManager.getActiveKeymap() : null;
//            if (activeKeymap != null) {
//                String findNextText = KeymapUtil.getFirstKeyboardShortcutText("FindNext");
//                String findPreviousText = KeymapUtil.getFirstKeyboardShortcutText("FindPrevious");
//                if (!StringUtil.isEmpty(findNextText) && !StringUtil.isEmpty(findPreviousText)) {
//                    myNavigationHintLabel.setText(FindBundle.message("label.use.0.and.1.to.select.usages", findNextText, findPreviousText));
//                }
//            }
//        }
    }

    private void updateScopeDetailsPanel() {
    }

    public void scheduleResultsUpdate() {
        if (myDialog == null || !myDialog.isVisible()) return;
        if (mySearchRescheduleOnCancellationsAlarm == null || mySearchRescheduleOnCancellationsAlarm.isDisposed())
            return;
        updateControls();
        mySearchRescheduleOnCancellationsAlarm.cancelAllRequests();
        mySearchRescheduleOnCancellationsAlarm.addRequest(this::findSettingsChanged, 100);
    }

    private void finishPreviousPreviewSearch() {
        if (myResultsPreviewSearchProgress != null && !myResultsPreviewSearchProgress.isCanceled()) {
            myResultsPreviewSearchProgress.cancel();
        }
    }

    private void findSettingsChanged() {
        ModalityState state = ModalityState.current();
        finishPreviousPreviewSearch();
        mySearchRescheduleOnCancellationsAlarm.cancelAllRequests();
//        applyTo(myHelper.getModel());
        FindModel findModel = new FindModel();
//        findModel.copyFrom(myHelper.getModel());
        if (findModel.getStringToFind().contains("\n")) {
            findModel.setMultiline(true);
        }

//        ValidationInfo result = getValidationInfo(myHelper.getModel());
//        myComponentValidator.updateInfo(result);

        ProgressIndicatorBase progressIndicatorWhenSearchStarted = new ProgressIndicatorBase() {
            @Override
            public void stop() {
                super.stop();
                onStop(System.identityHashCode(this));
                ApplicationManager.getApplication().invokeLater(() -> {
                    if (myNeedReset.compareAndSet(true, false)) { //nothing is found, let's clear previous results
                        reset();
                    }
                });
            }
        };
        myResultsPreviewSearchProgress = progressIndicatorWhenSearchStarted;
        int hash = System.identityHashCode(myResultsPreviewSearchProgress);

        // Use previously shown usage files as hint for faster search and better usage preview performance if pattern length increased
        Set<VirtualFile> filesToScanInitially = new LinkedHashSet<>();

//        if (myHelper.myPreviousModel != null && myHelper.myPreviousModel.getStringToFind().length() < myHelper.getModel().getStringToFind().length()) {
//            DefaultTableModel previousModel = (DefaultTableModel) myResultsPreviewTable.getModel();
//            for (int i = 0, len = previousModel.getRowCount(); i < len; ++i) {
//                Object value = previousModel.getValueAt(i, 0);
//                if (value instanceof FindPopupItem) {
//                    UsageInfoAdapter usage = ((FindPopupItem) value).getUsage();
//                    if (usage instanceof UsageInfo2UsageAdapter) {
//                        VirtualFile file = ((UsageInfo2UsageAdapter) usage).getFile();
//                        if (file != null) filesToScanInitially.add(file);
//                    }
//                }
//            }
//        }
//
//        myHelper.myPreviousModel = myHelper.getModel().clone();

        onStart(hash);
//        if (result != null && result.component != myReplaceComponent) {
//            onStop(hash, result.message);
//            reset();
//            return;
//        }

        FindInProjectExecutor projectExecutor = FindInProjectExecutor.Companion.getInstance();
//        GlobalSearchScope scope = GlobalSearchScopeUtil.toGlobalSearchScope(
//            FindInProjectUtil.getScopeFromModel(myProject, myHelper.myPreviousModel), myProject);
//        TableCellRenderer renderer = projectExecutor.createTableCellRenderer();
//        if (renderer == null) renderer = new UsageTableCellRenderer();
//        myResultsPreviewTable.getColumnModel().getColumn(0).setCellRenderer(renderer);

        AtomicInteger resultsCount = new AtomicInteger();
        AtomicInteger resultsFilesCount = new AtomicInteger();
        FindInProjectUtil.setupViewPresentation(myUsageViewPresentation, findModel);

        ProgressManager.getInstance().runProcessWithProgressAsynchronously(new Task.Backgroundable(myProject,
            FindBundle.message("find.usages.progress.title")) {
            @Override
            public void run(@NotNull ProgressIndicator indicator) {
                FindUsagesProcessPresentation processPresentation =
                    FindInProjectUtil.setupProcessPresentation(myProject, myUsageViewPresentation);
                ThreadLocal<String> lastUsageFileRef = new ThreadLocal<>();
//                ThreadLocal<Reference<FindPopupItem>> recentItemRef = new ThreadLocal<>();

                projectExecutor.findUsages(myProject, myResultsPreviewSearchProgress, processPresentation, findModel, filesToScanInitially, usage -> {
                    if (isCancelled()) {
                        onStop(hash);
                        return false;
                    }

                    if (resultsCount.getAndIncrement() >= ShowUsagesAction.getUsagesPageSize()) {
                        onStop(hash);
                        return false;
                    }

                    String file = lastUsageFileRef.get();
                    String usageFile = PathUtil.toSystemIndependentName(usage.getPath());
                    if (!usageFile.equals(file)) {
                        resultsFilesCount.incrementAndGet();
                        lastUsageFileRef.set(usageFile);
                    }

//                    FindPopupItem recentItem = SoftReference.dereference(recentItemRef.get());
//                    FindPopupItem newItem;
//                    boolean merged = !myHelper.isReplaceState() && recentItem != null && recentItem.getUsage().merge(usage);
//                    if (!merged) {
//                        newItem = new FindPopupItem(usage, usagePresentation(myProject, scope, usage));
//                    } else {
//                        // recompute presentation of a merged instance
//                        newItem = recentItem.withPresentation(usagePresentation(myProject, scope, recentItem.getUsage()));
//                    }
//                    recentItemRef.set(new WeakReference<>(newItem));

                    ApplicationManager.getApplication().invokeLater(() -> {
                        if (isCancelled()) {
                            onStop(hash);
                            return;
                        }
//                        myPreviewSplitter.getSecondComponent().setVisible(true);
//                        DefaultTableModel model = (DefaultTableModel) myResultsPreviewTable.getModel();
////                        if (!merged) {
////                            model.addRow(new Object[]{newItem});
////                        } else {
////                            model.fireTableRowsUpdated(model.getRowCount() - 1, model.getRowCount() - 1);
////                        }
//                        myCodePreviewComponent.setVisible(true);
//                        if (model.getRowCount() == 1) {
//                            myResultsPreviewTable.setRowSelectionInterval(0, 0);
//                        }
//                        int occurrences = resultsCount.get();
//                        int filesWithOccurrences = resultsFilesCount.get();
//                        myCodePreviewComponent.setVisible(occurrences > 0);
//                        myReplaceAllButton.setEnabled(occurrences > 0);
//                        myReplaceSelectedButton.setEnabled(occurrences > 0);
//
//                        if (occurrences > 0) {
//                            if (occurrences < ShowUsagesAction.getUsagesPageSize()) {
//                                myUsagesCount = String.valueOf(occurrences);
//                                myFilesCount = String.valueOf(filesWithOccurrences);
////                                header.infoLabel.setText(FindBundle.message("message.matches.in.files", occurrences, filesWithOccurrences));
//                            } else {
//                                myUsagesCount = occurrences + "+";
//                                myFilesCount = filesWithOccurrences + "+";
////                                header.infoLabel.setText(FindBundle.message("message.matches.in.files.incomplete", occurrences, filesWithOccurrences));
//                            }
//                        } else {
////                            header.infoLabel.setText("");
//                        }
                    }, state);

                    return true;
                });
            }

            @Override
            public void onCancel() {
                if (isShowing() && progressIndicatorWhenSearchStarted == myResultsPreviewSearchProgress) {
                    scheduleResultsUpdate();
                }
            }

            boolean isCancelled() {
                return progressIndicatorWhenSearchStarted != myResultsPreviewSearchProgress || progressIndicatorWhenSearchStarted.isCanceled();
            }

            @Override
            public void onFinished() {
                ApplicationManager.getApplication().invokeLater(() -> {
                    if (!isCancelled()) {
                        boolean isEmpty = resultsCount.get() == 0;
                        if (isEmpty) {
                            showEmptyText(FindBundle.message("message.nothingFound"));
                        }
                    }
                    onStop(hash);
                }, state);
            }
        }, myResultsPreviewSearchProgress);
    }

    private void reset() {
    }

    private void showEmptyText(@Nullable @NlsContexts.StatusText @NotNull String message) {
//        StatusText emptyText = myResultsPreviewTable.getEmptyText();
//        emptyText.clear();
//        FindModel model = myHelper.getModel();
        boolean dotAdded = false;
//        if (StringUtil.isEmpty(model.getStringToFind())) {
//            emptyText.setText(FindBundle.message("message.type.search.query"));
//        } else {
//            emptyText.setText(message);
//        }
//        if (mySelectedScope == FindPopupScopeUIImpl.DIRECTORY && !model.isWithSubdirectories()) {
//            emptyText.appendText(".");
//            dotAdded = true;
//            emptyText.appendSecondaryText(FindBundle.message("find.recursively.hint"),
//                SimpleTextAttributes.LINK_ATTRIBUTES,
//                e -> {
//                    model.setWithSubdirectories(true);
//                    scheduleResultsUpdate();
//                });
//        }
        List<Object> usedOptions = new SmartList<>();
//        if (model.isCaseSensitive() && isEnabled(myCaseSensitiveAction)) {
//            usedOptions.add(myCaseSensitiveAction);
//        }
//        if (model.isWholeWordsOnly() && isEnabled(myWholeWordsAction)) {
//            usedOptions.add(myWholeWordsAction);
//        }
//        if (model.isRegularExpressions() && isEnabled(myRegexAction)) {
//            usedOptions.add(myRegexAction);
//        }
        boolean couldBeRegexp = false;
        if (mySuggestRegexHintForEmptyResults) {
//            String stringToFind = model.getStringToFind();
//            if (!model.isRegularExpressions() && isEnabled(myRegexAction)) {
//                String regexSymbols = ".$|()[]{}^?*+\\";
//                for (int i = 0; i < stringToFind.length(); i++) {
//                    if (regexSymbols.indexOf(stringToFind.charAt(i)) != -1) {
//                        couldBeRegexp = true;
//                        break;
//                    }
//                }
//            }
//            if (couldBeRegexp) {
//                try {
//                    Pattern.compile(stringToFind);
//                    usedOptions.add(myRegexAction);
//                } catch (Exception e) {
//                    couldBeRegexp = false;
//                }
//            }
        }
        String fileTypeMask = getFileTypeMask();
        if (fileTypeMask != null && (FindInProjectUtil.createFileMaskCondition(fileTypeMask) != Conditions.<CharSequence>alwaysTrue())) {
//            usedOptions.add(header.cbFileFilter);
        }
    }

    private void onStart(int hash) {
        myNeedReset.set(true);
        myLoadingHash = hash;
    }


    private void onStop(int hash) {
        onStop(hash, FindBundle.message("message.nothingFound"));
    }

    private void onStop(int hash, @NotNull String message) {
        if (hash != myLoadingHash) {
            return;
        }
        UIUtil.invokeLaterIfNeeded(() -> {
            showEmptyText(message);
        });
    }

    @Override
    @Nullable
    public String getFileTypeMask() {
        String mask = null;
        return mask;
    }

    @Override
    @NotNull
    public String getStringToFind() {
        return "";
    }


    @NotNull
    private static FindModel.SearchContext parseSearchContext(String presentableName) {
        FindModel.SearchContext searchContext = FindModel.SearchContext.ANY;
        if (FindBundle.message("find.context.in.literals.scope.label").equals(presentableName)) {
            searchContext = FindModel.SearchContext.IN_STRING_LITERALS;
        } else if (FindBundle.message("find.context.in.comments.scope.label").equals(presentableName)) {
            searchContext = FindModel.SearchContext.IN_COMMENTS;
        } else if (FindBundle.message("find.context.except.comments.scope.label").equals(presentableName)) {
            searchContext = FindModel.SearchContext.EXCEPT_COMMENTS;
        } else if (FindBundle.message("find.context.except.literals.scope.label").equals(presentableName)) {
            searchContext = FindModel.SearchContext.EXCEPT_STRING_LITERALS;
        } else if (FindBundle.message("find.context.except.comments.and.literals.scope.label").equals(presentableName)) {
            searchContext = FindModel.SearchContext.EXCEPT_COMMENTS_AND_STRING_LITERALS;
        }
        return searchContext;
    }

}
