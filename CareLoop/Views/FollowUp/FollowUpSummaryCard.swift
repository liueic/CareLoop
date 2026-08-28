import SwiftUI

struct FollowUpSummaryCard: View {
    let followUp: FollowUp?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let followUp {
                FollowUpCountdownRing(date: followUp.date, size: 54, lineWidth: 4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("下次复诊")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.sage)
                        Spacer()
                        FollowUpCountdownBadge(
                            text: followUp.countdownText,
                            urgency: FollowUpService.urgencyLevel(for: followUp.date)
                        )
                    }
                    Text("\(followUp.department) · \(followUp.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareTheme.ink)
                    if !followUp.doctorName.isEmpty {
                        Label(followUp.doctorName, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    FollowUpChipRow(
                        icon: "exclamationmark.circle",
                        tint: CareTheme.warn,
                        items: followUp.effectiveRestrictions
                    )
                    FollowUpChipRow(
                        icon: "bag",
                        tint: CareTheme.sage,
                        items: followUp.effectiveMaterials
                    )
                }
            } else {
                FollowUpEmptyIllustration()
                VStack(alignment: .leading, spacing: 4) {
                    Text("下次复诊")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CareTheme.sage)
                    Text("添加下次复诊")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareTheme.ink)
                    Text("记录科室、医生与携带材料")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CareTheme.muted.opacity(0.8))
        }
        .padding(CareTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CareTheme.cardCornerRadius, style: .continuous)
                .fill(CareTheme.cardBackground)
                .shadow(color: CareTheme.ink.opacity(0.06), radius: 8, y: 2)
        )
        .overlay(alignment: .leading) {
            if let followUp {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(FollowUpService.urgencyLevel(for: followUp.date).tint)
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .padding(.leading, 4)
            }
        }
        .accessibilityIdentifier("followup.summaryCard")
    }
}
