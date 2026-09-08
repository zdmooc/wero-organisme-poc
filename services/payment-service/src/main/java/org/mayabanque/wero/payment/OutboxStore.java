package org.mayabanque.wero.payment;

import io.agroal.api.AgroalDataSource;
import io.quarkus.agroal.DataSource;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class OutboxStore {

    @Inject
    @DataSource("outbox")
    AgroalDataSource dataSource;

    /**
     * The outbox poller uses a dedicated non-JTA datasource. This keeps the
     * scheduler/Kafka path completely separate from the primary Hibernate/JTA
     * datasource used by consent and payment transactions.
     */
    public List<PendingEvent> loadPending(int batchSize) {
        String sql = """
                select id, aggregate_id, event_id, payload, correlation_id, traceparent
                  from outbox_events
                 where published_at is null
                 order by id
                 limit ?
                """;

        List<PendingEvent> result = new ArrayList<>();
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setInt(1, batchSize);
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    result.add(new PendingEvent(
                            rs.getLong("id"),
                            rs.getString("aggregate_id"),
                            rs.getString("event_id"),
                            rs.getString("payload"),
                            rs.getString("correlation_id"),
                            rs.getString("traceparent")));
                }
            }
            return result;
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to load pending outbox events", e);
        }
    }

    public void markPublished(Long id) {
        String sql = """
                update outbox_events
                   set published_at = ?,
                       publish_attempts = publish_attempts + 1,
                       last_error = null
                 where id = ?
                   and published_at is null
                """;
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, OffsetDateTime.now(ZoneOffset.UTC));
            statement.setLong(2, id);
            statement.executeUpdate();
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to mark outbox event published id=" + id, e);
        }
    }

    public void markFailed(Long id, String error) {
        String sql = """
                update outbox_events
                   set publish_attempts = publish_attempts + 1,
                       last_error = ?
                 where id = ?
                   and published_at is null
                """;
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, error);
            statement.setLong(2, id);
            statement.executeUpdate();
        } catch (SQLException e) {
            throw new IllegalStateException("Unable to mark outbox event failed id=" + id, e);
        }
    }

    public record PendingEvent(
            Long id,
            String aggregateId,
            String eventId,
            String payload,
            String correlationId,
            String traceparent) {
    }
}
