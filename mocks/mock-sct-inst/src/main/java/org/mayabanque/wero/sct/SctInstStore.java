package org.mayabanque.wero.sct;

import io.agroal.api.AgroalDataSource;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Optional;
import java.util.UUID;

@ApplicationScoped
public class SctInstStore {

    @Inject AgroalDataSource dataSource;

    @PostConstruct
    void initialize() {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    create table if not exists sct_inst_transfers (
                        payment_id varchar(128) primary key,
                        status varchar(32) not null,
                        settlement_id varchar(128) not null,
                        created_at timestamptz not null default now()
                    )
                    """);
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to initialize shared SCT Inst transfer store", e);
        }
    }

    public StoredTransfer settle(String paymentId) {
        String candidateSettlementId = "SCT-" + UUID.randomUUID();
        try (Connection connection = dataSource.getConnection();
             PreparedStatement insert = connection.prepareStatement("""
                     insert into sct_inst_transfers(payment_id, status, settlement_id)
                     values (?, 'SETTLED', ?)
                     on conflict (payment_id) do nothing
                     """)) {
            insert.setString(1, paymentId);
            insert.setString(2, candidateSettlementId);
            insert.executeUpdate();
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to persist SCT Inst settlement for payment " + paymentId, e);
        }

        return find(paymentId)
                .orElseThrow(() -> new IllegalStateException("SCT Inst settlement disappeared for payment " + paymentId));
    }

    public Optional<StoredTransfer> find(String paymentId) {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement query = connection.prepareStatement("""
                     select payment_id, status, settlement_id
                     from sct_inst_transfers
                     where payment_id = ?
                     """)) {
            query.setString(1, paymentId);
            try (ResultSet rs = query.executeQuery()) {
                if (!rs.next()) return Optional.empty();
                return Optional.of(new StoredTransfer(rs.getString(1), rs.getString(2), rs.getString(3)));
            }
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to read SCT Inst settlement for payment " + paymentId, e);
        }
    }

    public record StoredTransfer(String paymentId, String status, String settlementId) {}
}
