import FilmTemplateKit
import Foundation
import JSONSchema
import JSONSchemaForm
import SwiftUI

/// The brief: the only page the user fills in by hand.
public struct IntakeFormView: View {
    let template: FilmTemplate
    @Binding var formData: FormData
    let onSubmit: (IntakeSubmission) -> Void
    /// Back to the page before this one, when there is one.
    let onBack: (() -> Void)?
    let onCancel: () -> Void

    @State private var controller = JSONSchemaFormController()
    @State private var decoded: DecodedForm?
    /// The name we last filled in ourselves. While the field still holds it,
    /// typing a new website replaces it; once the user edits the name, it is
    /// theirs and we stop touching it.
    @State private var autoName: String?

    public init(
        template: FilmTemplate,
        formData: Binding<FormData>,
        onSubmit: @escaping (IntakeSubmission) -> Void,
        onBack: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.template = template
        self._formData = formData
        self.onSubmit = onSubmit
        self.onBack = onBack
        self.onCancel = onCancel
    }

    public var body: some View {
        WizardShell(
            title: LocalizedStringKey(template.title),
            subtitle: LocalizedStringKey(template.summary),
            current: .intake,
            onCancel: onCancel
        ) {
            Group {
                if let decoded {
                    // The grouped style is what makes this read as a settings
                    // sheet rather than a wall of unlabelled boxes: each field
                    // gets its own inset row, with the schema's description as
                    // that row's footer.
                    Form {
                        Section {
                            JSONSchemaForm(
                                schema: decoded.schema,
                                uiSchema: decoded.uiSchema,
                                formData: $formData,
                                schemaJSON: template.intake.schemaJSON,
                                liveValidate: false,
                                showErrorList: true,
                                showSubmitButton: false,
                                widgets: [
                                    FilePickerWidget.name: FilePickerWidget.widget,
                                    WebsiteWidget.name: WebsiteWidget.widget,
                                ],
                                controller: controller
                            )
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                } else {
                    WizardErrorView(
                        message: String(localized: "This template's form could not be read."),
                        onRetry: nil,
                        onCancel: onCancel
                    )
                }
            }
            .accessibilityIdentifier("intake.form")
        } footer: {
            if let onBack {
                Button("Back", action: onBack)
                    .accessibilityIdentifier("intake.back")
            }
            Button("Continue", action: submit)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(decoded == nil)
                .accessibilityIdentifier("intake.continue")
        }
        .task { decoded = DecodedForm(template.intake) }
        .onChange(of: websiteValue) { _, newValue in suggestName(from: newValue) }
    }

    private var websiteValue: String {
        formData.object?[IntakeFormDefinition.Field.website]?.string ?? ""
    }

    private var nameValue: String {
        formData.object?[IntakeFormDefinition.Field.projectName]?.string ?? ""
    }

    private func suggestName(from website: String) {
        guard nameValue.isEmpty || nameValue == autoName else { return }
        guard let suggestion = IntakeSubmission.suggestedName(for: website) else { return }
        var object = formData.object ?? [:]
        object[IntakeFormDefinition.Field.projectName] = .string(suggestion)
        formData = .object(properties: object)
        autoName = suggestion
    }

    private func submit() {
        guard controller.validate() else { return }
        let values = (formData.toDictionary() as? [String: Any]) ?? [:]
        onSubmit(IntakeSubmission(formValues: values))
    }
}

/// The schema and uiSchema, parsed once.
///
/// `uiSchema` is `[String: Any]` and so cannot cross an isolation boundary;
/// building it inside the view keeps it on the main actor where it is used.
struct DecodedForm {
    let schema: JSONSchema
    let uiSchema: [String: Any]?

    init?(_ definition: IntakeFormDefinition) {
        guard let schemaData = definition.schemaJSON.data(using: .utf8),
              let schema = try? JSONDecoder().decode(JSONSchema.self, from: schemaData)
        else { return nil }
        self.schema = schema
        self.uiSchema = definition.uiSchemaJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }
}
