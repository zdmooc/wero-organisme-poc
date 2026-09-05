package org.mayabanque.wero.gateway;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/audit/events")
@Produces(MediaType.APPLICATION_JSON)
@RegisterRestClient(configKey = "audit-backend")
public interface AuditBackendClient {

    @GET
    @Path("/{paymentId}")
    Response byPayment(
            @HeaderParam("Authorization") String authorization,
            @HeaderParam("X-Correlation-Id") String correlationId,
            @PathParam("paymentId") String paymentId);
}
