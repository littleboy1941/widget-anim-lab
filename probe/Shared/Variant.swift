// Что показывает первый виджет («Probe 0»), который UI-тест ставит на домашний экран.
// CI перезаписывает этот файл для каждого задания матрицы (font-probe.yml).
// Новая матрица: len160s, len80c20, split160, grp80, grp160.
// Старые режимы overlap, lenN, memN и diag остаются доступны.
enum Variant {
    static let mode = "overlap"
}
