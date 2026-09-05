package org.mayabanque.wero.payment;

import io.quarkus.hibernate.orm.panache.PanacheEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import java.time.Instant;

@Entity
@Table(name = "ledger_entries")
public class LedgerEntryEntity extends PanacheEntity {
    @Column(name = "payment_id", nullable = false, length = 80)
    public String paymentId;

    @Column(name = "entry_type", nullable = false, length = 40)
    public String entryType;

    @Column(name = "amount_cents", nullable = false)
    public long amountCents;

    @Column(nullable = false, length = 3)
    public String currency;

    @Column(name = "settlement_id", length = 120)
    public String settlementId;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;
}
